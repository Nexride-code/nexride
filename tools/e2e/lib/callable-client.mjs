import { initializeApp } from "firebase/app";
import { connectAuthEmulator, getAuth, signInWithCustomToken } from "firebase/auth";
import { connectFunctionsEmulator, getFunctions, httpsCallable } from "firebase/functions";
import { EMULATOR, E2E_PROJECT_ID } from "../config/emulator.mjs";
import { auth as adminAuth } from "./admin.mjs";

let clientApp;
let clientAuth;
let clientFunctions;

function getClient() {
  if (!clientApp) {
    clientApp = initializeApp({
      projectId: E2E_PROJECT_ID,
      apiKey: "e2e-fake-api-key",
      authDomain: "localhost",
    });
    clientAuth = getAuth(clientApp);
    connectAuthEmulator(
      clientAuth,
      `http://${EMULATOR.authHost}:${EMULATOR.authPort}`,
      { disableWarnings: true },
    );
    clientFunctions = getFunctions(clientApp, EMULATOR.functionsRegion);
    connectFunctionsEmulator(
      clientFunctions,
      EMULATOR.functionsHost,
      EMULATOR.functionsPort,
    );
  }
  return { auth: clientAuth, functions: clientFunctions };
}

export async function signInActor(uid, claims = {}) {
  const token = await adminAuth().createCustomToken(uid, claims);
  const { auth: fbAuth } = getClient();
  const cred = await signInWithCustomToken(fbAuth, token);
  return cred.user;
}

export async function invokeCallable(name, data, uid, claims = {}) {
  await signInActor(uid, claims);
  const { functions } = getClient();
  const fn = httpsCallable(functions, name);
  const res = await fn(data ?? {});
  return res.data;
}
