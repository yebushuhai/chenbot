import { createHash } from 'node:crypto';
/** Orchestration contract. Database and auth adapters must be implemented and
 * independently audited before exposing any public endpoint. */
export async function recognizeForUser({accessToken, requestId, image, mimeType, language}, deps) {
  if (!accessToken || typeof accessToken !== 'string') throw new Error('Authentication required');
  if (typeof requestId !== 'string' || !/^[a-zA-Z0-9_-]{16,100}$/.test(requestId)) throw new Error('Invalid request id');
  if (!Buffer.isBuffer(image) || image.length === 0 || image.length > 8 * 1024 * 1024) throw new Error('Invalid image');
  if (!['en','ja'].includes(language) || !['image/jpeg','image/png'].includes(mimeType)) throw new Error('Invalid request');
  if (!deps?.authenticate || !deps?.reserve || !deps?.recognize || !deps?.finish) throw new Error('Service is not configured');
  const user = await deps.authenticate(accessToken);
  if (!user?.id) throw new Error('Authentication required');
  // reserve must atomically enforce the server-defined quota, associate the
  // request with this user, and reject a different payload for the same id.
  const imageHash = createHash('sha256').update(image).digest('hex');
  const reservation = await deps.reserve({userId:user.id, requestId, imageHash, mimeType, language});
  if (reservation.status === 'completed') return reservation.result;
  if (reservation.status === 'pending') throw new Error('Recognition already in progress');
  if (reservation.status === 'insufficient') throw new Error('Insufficient credits');
  if (reservation.status !== 'reserved') throw new Error('Cannot reserve credit');
  let result;
  try { result = await deps.recognize({image,mimeType,language}); }
  catch (error) {
    // The persistence adapter must make this idempotent and recover abandoned
    // reservations if either the provider or this operation fails.
    await deps.finish({userId:user.id,requestId,status:'failed'});
    throw error;
  }
  // If persistence fails after recognition, do not issue a refund here: the
  // client retries the same id and a recovery worker must reconcile the state.
  await deps.finish({userId:user.id,requestId,status:'completed',result});
  return result;
}
