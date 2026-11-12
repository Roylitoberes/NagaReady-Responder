const { onDocumentCreated } = require("firebase-functions/v2/firestore");
const { setGlobalOptions } = require("firebase-functions/v2");
const { initializeApp } = require("firebase-admin/app");
const { getFirestore } = require("firebase-admin/firestore");
const { getMessaging } = require("firebase-admin/messaging");
const logger = require("firebase-functions/logger");

// Initialize admin SDK
initializeApp();

// Keep max instances low (cost control)
setGlobalOptions({ maxInstances: 10 });

/**
 * Fires when a new doc is added to responder_notifications.
 * Sends a push to the target responder's device via FCM.
 * Works even when the responder's app is fully closed.
 */
exports.sendIncidentNotification = onDocumentCreated(
  "responder_notifications/{docId}",
  async (event) => {
    const snapshot = event.data;
    if (!snapshot) {
      logger.warn("❌ No snapshot data");
      return null;
    }

    const data = snapshot.data();
    const userId = data.userId;

    if (!userId) {
      logger.warn("❌ No userId in document, skipping");
      return null;
    }

    const db = getFirestore();

    // ✅ Read FCM token from responder_tokens/{userId}
    //    (this is where your Flutter app saves it)
    const tokenDoc = await db.collection("responder_tokens").doc(userId).get();

    if (!tokenDoc.exists) {
      logger.warn(`❌ No FCM token doc for user ${userId} in responder_tokens`);
      return null;
    }

    const token = tokenDoc.data().token;

    if (!token) {
      logger.warn(`❌ Empty token for user ${userId}`);
      return null;
    }

    const incidentId = event.params.docId;
    const type = String(data.type || "Emergency");
    const location = String(data.location || "Unknown location");
    const unitName = String(data.unitName || "");

    // ✅ Message includes BOTH notification + data blocks
    //    The `notification` block is REQUIRED so Android shows
    //    the notification when the app is fully closed.
    const message = {
      token: token,

      // ✅ THIS IS WHAT MAKES IT SHOW WHEN APP IS CLOSED
      notification: {
        title: `🚨 New Incident: ${type}`,
        body: `${location}${unitName ? " • " + unitName : ""}`,
      },

      // Data payload (received by Flutter when tapped)
      data: {
        incidentId: String(incidentId),
        type: type,
        location: location,
        unitName: unitName,
      },

      android: {
        priority: "high",
        // ✅ Channel + sound REQUIRED for the notification to display
        notification: {
          channelId: "incident_alerts_v2",
          sound: "default",
          priority: "max",
          defaultVibrateTimings: true,
        },
      },

      apns: {
        headers: {
          "apns-priority": "10",
        },
        payload: {
          aps: {
            sound: "default",
            badge: 1,
          },
        },
      },
    };

    try {
      const response = await getMessaging().send(message);
      logger.info("✅ FCM sent:", response);
      return response;
    } catch (err) {
      logger.error("❌ FCM send failed:", err);

      // Clean up stale tokens
      if (
        err.code === "messaging/invalid-registration-token" ||
        err.code === "messaging/registration-token-not-registered"
      ) {
        logger.info(`🗑️ Removing stale token for user ${userId}`);
        await db.collection("responder_tokens").doc(userId).delete();
      }

      return null;
    }
  }
);