/**
 * VIBE — LiveKit Token Server
 *
 * Add these routes to your existing Express server on DigitalOcean (port 3001).
 *
 * SETUP:
 *   npm install livekit-server-sdk
 *
 * DEPLOYED — credentials are hardcoded in orchestrator index.js:
 *   LIVEKIT_API_KEY    = vibe_lk_2026
 *   LIVEKIT_API_SECRET = 50562eef6a9e9b83167dc3c830d0b60a6e698ad6fc485da5b79e357490e4446e
 *   LIVEKIT_URL        = wss://naluask.com/livekit
 *   Token endpoints    = https://naluask.com/api/livekit/creator-token
 *                        https://naluask.com/api/livekit/viewer-token
 *
 * DOCKER (run on DO alongside NaluAsk):
 *   See livekit-docker-compose.yml in this folder.
 */

const { AccessToken } = require('livekit-server-sdk');

const LIVEKIT_API_KEY    = process.env.LIVEKIT_API_KEY;
const LIVEKIT_API_SECRET = process.env.LIVEKIT_API_SECRET;

/**
 * POST /api/livekit/creator-token
 * Body: { roomName, participantName, tenantId }
 * Returns: { token, roomName }
 *
 * Creator gets full publish + admin rights.
 */
async function creatorToken(req, res) {
  try {
    const { roomName, participantName, tenantId } = req.body;
    if (!roomName || !participantName || !tenantId) {
      return res.status(400).json({ error: 'roomName, participantName, tenantId required' });
    }
    const fullRoom = `${tenantId}_${roomName}`;
    const at = new AccessToken(LIVEKIT_API_KEY, LIVEKIT_API_SECRET, {
      identity: `creator_${tenantId}_${Date.now()}`,
      name: participantName,
      ttl: 7200, // 2 hours
    });
    at.addGrant({
      roomJoin:       true,
      room:           fullRoom,
      canPublish:     true,
      canSubscribe:   true,
      canPublishData: true,
      roomAdmin:      true,
      roomCreate:     true,
    });
    res.json({ token: await at.toJwt(), roomName: fullRoom });
  } catch (err) {
    console.error('[LiveKit creator-token]', err);
    res.status(500).json({ error: 'Token generation failed' });
  }
}

/**
 * POST /api/livekit/viewer-token
 * Body: { roomName, viewerName, tenantId }
 * Returns: { token, roomName }
 *
 * Viewer can publish their own cam/mic but cannot admin the room.
 */
async function viewerToken(req, res) {
  try {
    const { roomName, viewerName, tenantId } = req.body;
    if (!roomName || !viewerName || !tenantId) {
      return res.status(400).json({ error: 'roomName, viewerName, tenantId required' });
    }
    const fullRoom = `${tenantId}_${roomName}`;
    const at = new AccessToken(LIVEKIT_API_KEY, LIVEKIT_API_SECRET, {
      identity: `viewer_${Date.now()}_${viewerName.replace(/\s+/g, '_')}`,
      name: viewerName,
      ttl: 7200,
    });
    at.addGrant({
      roomJoin:       true,
      room:           fullRoom,
      canPublish:     true,   // viewers can share cam/mic
      canSubscribe:   true,
      canPublishData: true,   // for chat + raise-hand events
      roomAdmin:      false,
    });
    res.json({ token: await at.toJwt(), roomName: fullRoom });
  } catch (err) {
    console.error('[LiveKit viewer-token]', err);
    res.status(500).json({ error: 'Token generation failed' });
  }
}

/**
 * Register routes — call this from your main server.js:
 *
 *   const livekit = require('./livekit-tokens');
 *   livekit.register(app);
 */
function register(app) {
  app.post('/api/livekit/creator-token', creatorToken);
  app.post('/api/livekit/viewer-token',  viewerToken);
}

module.exports = { register, creatorToken, viewerToken };
