/**
 * Not a Firebase deploy source — see ../nexride_driver/functions and firebase.json.
 * Kept so local tooling that expects this path fails fast with a clear message.
 */
throw new Error(
  "Root functions/ is not deployed. Configure Firebase with nexride_driver/functions (firebase.json).",
);
