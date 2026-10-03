// Shared by pricing.html and activate.html: Google sign-in through the ZeroCurse Firebase project, and the calls to the ZeroCurse service.
// Nothing secret lives here. All checks happen on the server.
const FB = "https://www.gstatic.com/firebasejs/10.12.2/";
let _auth = null, _mods = null;

export const ready = () => !!(window.ZC.api && window.ZC.firebase.apiKey);

async function auth() {
  if (_auth) return _auth;
  const app = await import(FB + "firebase-app.js");
  _mods = await import(FB + "firebase-auth.js");
  _auth = _mods.getAuth(app.initializeApp(window.ZC.firebase));
  return _auth;
}

/** Opens the Google sign-in window; resolves to {uid, email, idToken}. */
export async function signIn() {
  const a = await auth();
  const res = await _mods.signInWithPopup(a, new _mods.GoogleAuthProvider());
  return { uid: res.user.uid, email: res.user.email, idToken: await res.user.getIdToken() };
}

/** Approves a code shown in the computer app, so that app is signed in as this account. */
export async function approveDevice(userCode, idToken) {
  const r = await fetch(window.ZC.api.replace(/\/+$/, "") + "/v1/auth/device/approve", {
    method: "POST", headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ user_code: userCode, id_token: idToken }),
  });
  const body = await r.json().catch(() => ({}));
  if (!r.ok) throw new Error(typeof body.detail === "string" ? body.detail : (body.detail && body.detail.error) || "Could not sign in the app (" + r.status + ")");
  return body;
}

/** Sends the signed-in buyer to the payment page for a product. The account id and email ride along so the purchase lands on the right account. */
export function checkoutUrl(product, who) {
  const base = window.ZC.checkout[product];
  if (!base) return null;
  const u = new URL(base);
  u.searchParams.set("client_reference_id", who.uid);
  u.searchParams.set("prefilled_email", who.email);
  return u.toString();
}
