// ZeroCurse website settings. Everything the pages need from the owner goes here; a page shows "coming soon" for anything left empty.
// None of these are secrets: the Firebase web config and Stripe payment links are public by design.
window.ZC = {
  // ZeroCurse's OWN cloud service (never the Smart Teacher project), e.g. "https://zerocurse-cloud-xxxxx.a.run.app"
  api: "",
  // Firebase web app config of the ZeroCurse Firebase project (Project settings > Your apps > Web app)
  firebase: { apiKey: "", authDomain: "", projectId: "", appId: "" },
  // Where the free Windows download is hosted (a direct link to the .zip)
  windowsDownload: "",
  // Google Play listing of the phone app
  playStore: "",
  // Stripe Payment Links (or Paddle checkout links) per product. The page adds ?client_reference_id=<account id>&prefilled_email=<email>.
  checkout: {
    pro: "",
    zc_clean_100: "",
    zc_clean_150: "",
    zc_clean_200: "",
    zc_clean_250: "",
    zc_clean_300: ""
  },
  supportEmail: "support@philosoftventures.com"
};
