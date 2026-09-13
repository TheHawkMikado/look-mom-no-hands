import { useEffect, useRef } from "react";
import * as Notifications from "expo-notifications";
import { getSettings } from "../lib/api";
import { syncDeviceRegistration } from "../lib/device";
import { NotificationTarget, parseNotificationData } from "../lib/notificationData";
import { configureForegroundPresentation, registerForPush } from "../lib/push";
import { navigationRef } from "../navigation";
import { useFeed } from "../state/FeedContext";
import { useTasks } from "../state/TasksContext";

/**
 * Renders nothing. Mounted once inside the providers and the navigation
 * container while signed in:
 *  - registers the phone (with its Expo push token unless the account has
 *    push turned off) on sign-in,
 *  - refreshes the feed and prompts when a push arrives in the foreground,
 *  - routes notification taps: approvalId → Talk (the approval card lives
 *    there), promptId → Tasks with the prompt highlighted.
 */
export function PushBridge() {
  const { refresh: refreshFeed } = useFeed();
  const { refreshOutstanding } = useTasks();
  const refreshFeedRef = useRef(refreshFeed);
  refreshFeedRef.current = refreshFeed;
  const refreshTasksRef = useRef(refreshOutstanding);
  refreshTasksRef.current = refreshOutstanding;

  useEffect(() => {
    configureForegroundPresentation();
    let alive = true;

    void (async () => {
      // Respect a server-side "push off" — otherwise re-registering would
      // silently hand the server a token it was told not to use.
      const settings = await getSettings().catch(() => null);
      const pushWanted = settings?.push_enabled !== false;
      const token = pushWanted ? await registerForPush() : null;
      if (alive) await syncDeviceRegistration(token);
    })();

    const received = Notifications.addNotificationReceivedListener(() => {
      void refreshFeedRef.current();
      void refreshTasksRef.current();
    });
    const responded = Notifications.addNotificationResponseReceivedListener((response) => {
      // The poll may not have caught up with what the push announced.
      void refreshFeedRef.current();
      void refreshTasksRef.current();
      open(parseNotificationData(response.notification.request.content.data));
    });
    // Cold start from a tap: the response predates these listeners.
    void Notifications.getLastNotificationResponseAsync().then((response) => {
      if (!alive || !response) return;
      const target = parseNotificationData(response.notification.request.content.data);
      if (target) {
        openWhenReady(target);
        void Notifications.clearLastNotificationResponseAsync().catch(() => undefined);
      }
    });

    return () => {
      alive = false;
      received.remove();
      responded.remove();
    };
  }, []);

  return null;
}

function open(target: NotificationTarget): void {
  if (!target || !navigationRef.isReady()) return;
  if (target.kind === "approval") navigationRef.navigate("Talk");
  else navigationRef.navigate("Tasks", { promptId: target.promptId });
}

/** Cold start: the container may not be ready the instant the response is read. */
function openWhenReady(target: NotificationTarget, attempt = 0): void {
  if (navigationRef.isReady()) {
    open(target);
    return;
  }
  if (attempt > 20) return;
  setTimeout(() => openWhenReady(target, attempt + 1), 100);
}
