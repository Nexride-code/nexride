/// Canonical backend-controlled job states (mirrored to RTDB `liveJobs`).
class CanonicalJobState {
  CanonicalJobState._();

  static const String requestPending = 'REQUEST_PENDING';
  static const String searchingDriver = 'SEARCHING_DRIVER';
  static const String driverOffered = 'DRIVER_OFFERED';
  static const String driverAssigned = 'DRIVER_ASSIGNED';
  static const String driverArriving = 'DRIVER_ARRIVING';
  static const String driverArrived = 'DRIVER_ARRIVED';
  static const String inProgress = 'IN_PROGRESS';
  static const String completed = 'COMPLETED';
  static const String paymentPending = 'PAYMENT_PENDING';
  static const String paid = 'PAID';
  static const String closed = 'CLOSED';
  static const String cancelled = 'CANCELLED';
}

/// RTDB paths for lightweight realtime mirrors (not business authority).
class LiveRtdbPaths {
  LiveRtdbPaths._();

  static String liveJob(String jobId) => 'liveJobs/${jobId.trim()}';
  static String liveDriver(String driverId) => 'liveDrivers/${driverId.trim()}';
  static String jobChatMessage(String jobId, String messageId) =>
      'ride_chats/${jobId.trim()}/messages/${messageId.trim()}';
}
