# Google Play Store Listing — Smart Teacher

Draft copy for the Play Console store listing form. All character counts verified against Play Console's actual limits before finalizing here.

## App name (30 chars max)

**Smart Teacher** (13 chars — matches the app's existing identity everywhere else; no need to change it)

## Short description (80 chars max) — pick one

1. `AI lesson planning, marking, and school tools for Zambian CBC/OBC teachers` (74 chars)
2. `Plan lessons, mark scripts with AI, and run your school — built for Zambia` (74 chars)
3. `Lesson plans, AI marking, timetables, and past papers for Zambian schools` (73 chars)

Recommendation: **#1** — leads with "CBC/OBC," which is exactly what a Zambian teacher searching Play Store would type.

## Full description (4000 chars max, currently 3258)

```
Smart Teacher is a planning, marking, and school-management app built specifically for Zambia's CBC (Competence-Based Curriculum, Forms 1–2) and OBC (Outcome-Based Curriculum, Grades 10–12) — for teachers and for the pupils they teach.

FOR TEACHERS

Lesson planning, grounded in the real curriculum
• Generate Lesson Plans, Schemes of Work, and Teaching Notes tied to real CDC syllabus competencies and objectives — not generic AI guesses.
• Record of Work, auto-captured as you teach.
• Offline access to a built-in library of CBC/OBC syllabi, Teaching Modules, and ECZ past examination papers.

AutoGrade — AI-assisted marking
• Photograph student scripts and let AI produce a first-pass mark and comment against your own marking key — you review and confirm every score.
• Results Analysis with class performance graphs, once a cohort is marked.
• Individual student performance reports, shareable in one tap.

Home Assignment
• Issue an assignment to a class; a marking key is generated and saved automatically.
• Pupils submit in-app, by WhatsApp import, or by emailing a photographed answer sheet — everything lands in one queue.
• AI marks submissions against your key; share a results list to the whole class in seconds.

School Network
• Register your school or join with a code; connect classes, assign subject teachers, and track scores together as a staff.
• Staffroom for school-wide announcements and pinned notices.
• Broadcast messages and Home Assignments to guardians by email, with one-tap WhatsApp for anything more personal.

Timetable Generation
• A deterministic engine builds a full-school timetable with no double-booking, respecting teacher availability — describe availability in plain language and let AI turn it into constraints.
• Read an existing paper timetable straight from a photo.
• Need a timetable for a different institution entirely — one with no account of its own? Build one from scratch, completely separate from your own school's data.

Admin Tools
• Convert Word documents to PDF and back, on-device.
• Minutes Maker: record a meeting, get structured minutes (attendees, agenda, decisions, action items).
• Handwriting-to-Word transcription for any handwritten document.
• Broad Mark Sheet / Report Form pipeline: photograph a paper score sheet and generate report cards, composite subjects, and class rankings.

FOR PUPILS

• Submit a handwritten assignment or test by photographing it — with proof of submission sent straight to your teacher.
• Receive and answer Home Assignments issued by your subject teachers, marked automatically.
• Join your class with a simple code from your teacher, so nothing gets missed.
• Download real past examination papers from the Examinations Council of Zambia (ECZ), free to browse and save.

BUILT FOR HOW ZAMBIAN SCHOOLS ACTUALLY WORK

Core planning and content browsing work fully offline — only AI-assisted features (marking, generation, transcription) need a connection. Every piece of curriculum content is sourced from real CDC and ECZ material, never invented.

Smart Teacher is under active development — new features ship regularly based on real feedback from the teachers and pupils using it.
```

## Category

**Education** (no other category fits — do not pick "Productivity" even though some tools overlap, since the app is fundamentally curriculum/school-specific).

## Contact details

- Email: `kampmapa1@gmail.com`
- Website: none yet — optional at this stage; Play Console only requires it for later verification steps, not initial submission. Could point to the GitHub repo (`github.com/kampmapa1-design/zambian-curriculum-app`) as a placeholder if a website field is required and nothing else exists.
- Privacy policy URL: `https://zambian-curriculum-app.web.app/privacy-policy.html` (already deployed)

## Not included here — needs real assets from you

- **App icon** (512×512 PNG, no alpha) — the existing `android/app/src/main/res/mipmap-*/ic_launcher.png` files exist for the app itself, but Play Console's store-listing icon needs a dedicated 512×512 hi-res version; I can resize the existing icon if you want to use it as-is, or you may want a fresh one designed for the store listing specifically.
- **Feature graphic** (1024×500 PNG/JPG) — a banner image Play Store shows at the top of the listing. Not something I can meaningfully generate without knowing your visual preference — happy to draft a simple one if you describe what you want, or you can skip this for a closed/internal testing track (only required for public production release).
- **Screenshots** (min 2, phone: 16:9 or 9:16, various sizes accepted) — need real screenshots from a running device. I can help capture these once the app bundle is on a device via the Browser pane's mobile emulation isn't applicable here (native app, not web) — these should come from your own phone.

## What's still ahead

- **Content rating questionnaire** and **Data safety section** — I can draft the exact answers next, based on the same data-flow audit behind the privacy policy rewrite.
