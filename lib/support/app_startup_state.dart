class AppStartupState {
  const AppStartupState({
    required this.firebaseReady,
    this.safeErrorMessage,
  });

  final bool firebaseReady;
  final String? safeErrorMessage;
}
