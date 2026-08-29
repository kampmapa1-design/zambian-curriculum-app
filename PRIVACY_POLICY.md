# Privacy Policy — Smart Teacher

**Effective date:** August 29, 2026

Smart Teacher ("the app") is developed by Kampamba Mashabe ("we", "us"). This policy explains what data the app collects, why, and how it is handled. It applies to the Android app distributed on Google Play under the package name `com.kampmapa1design.smartteacher`.

## Summary

Smart Teacher is built offline-first. Lesson plans, schemes of work, captured scripts, and marking records are generated and stored **on your device only**. The app does not run ads, does not use analytics or tracking SDKs, and does not sell or share your data with advertisers. The only data that ever leaves your device is described below, and only when you actively use an AI-assisted feature.

## What we collect and why

**1. Camera access.** The app requests camera permission to let you photograph documents — question papers, marking keys, student scripts, and handwritten score lists. Captured photos are processed on-device (cropping, deskewing, contrast enhancement) and stored locally. They are only sent off-device if you choose an AI-assisted feature (see below).

**2. AI-assisted features (optional, only when you use them).** Features such as AI-assisted marking, marking-key generation from a photographed paper, and handwritten-list transcription send the relevant photographed page(s) and/or text to our backend (Google Cloud Functions), which forwards them to Google's Gemini AI service for one-time processing and returns the result to your device. We do not store these images or the AI's responses on our servers — they pass through for processing and are not retained by us. Google's own handling of data sent to its AI services is governed by Google's Privacy Policy (https://policies.google.com/privacy) and Gemini API terms.

**3. Anonymous app identifier.** To prevent abuse of the AI processing quota, the app signs in anonymously via Firebase Authentication before calling an AI feature. This creates a random device-associated identifier — no name, email address, phone number, or other personal identifier is collected or requested by the app itself.

**4. Locally-stored content.** Everything else the app generates or that you enter — lesson plans, schemes of work, record of work, captured scripts, marking schemes, grades, and analysis documents — is stored in a local database on your device and is never transmitted to us. Documents you choose to share (Word/PDF exports) go through your device's own share menu, entirely under your control; we have no visibility into where they end up.

## What we do **not** do

- We do not run advertising or use any advertising SDK in this version of the app.
- We do not use analytics, crash-reporting, or tracking SDKs.
- We do not collect your name, email address, location, contacts, or any other personal profile information.
- We do not sell your data, and we do not share it with third parties for their own marketing purposes.

*(If a future version adds advertising, in-app purchases, or account sign-in, this policy will be updated first, and the update will be reflected in the app's Play Store listing.)*

## Data retention and deletion

Since your content is stored on your device, uninstalling the app deletes it. Photos sent for AI processing are not retained by us after the response is returned. If you have questions about a specific processing request, contact us using the details below.

## Children's privacy

Smart Teacher is a professional tool intended for teachers and educators, not for use by children. We do not knowingly collect personal information from children.

## Changes to this policy

We may update this policy as the app's features change. The effective date above reflects the most recent update.

## Contact

Questions about this policy or your data can be sent to: **kampmapa1@gmail.com**
