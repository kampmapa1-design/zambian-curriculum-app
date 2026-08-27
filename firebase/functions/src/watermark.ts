import { deflateSync, inflateSync } from "zlib";
import { PDFDocument, PDFDict, PDFName, PDFArray, PDFStream, PDFRawStream, PDFRef, PDFContext } from "pdf-lib";

// ---------------------------------------------------------------------
// Strips branding watermarks that redistribution sites (zedpastpapers.com,
// zambiapapers.com, etc.) stamp onto past-paper PDFs before ECZ papers ever
// reach this app. Investigated against a real sample (2026-08-27,
// history_paper_1_2022.pdf) rather than guessed: the watermark is NOT
// baked into the scanned page image. It's a small (~536x72px), separate,
// semi-transparent (has an /SMask) image, wrapped in its own Form XObject,
// placed at a fixed spot on every page via one extra "cm ... Do" draw call
// in that page's content stream — completely distinct from the big
// full-page scan image, which is the real exam content and is never
// touched by any of this.
//
// Detection heuristic (deliberately conservative — a false negative just
// leaves a watermark in place; a false positive could damage real exam
// content, which is the worse failure):
//   - An Image XObject counts as a watermark candidate only if it has an
//     /SMask (transparency — real scanned page content has no reason to
//     be semi-transparent) AND is small (under 60,000px^2 — the sample
//     was 38,592) AND wide relative to its height (a banner shape, not a
//     square diagram).
//   - A Form XObject counts as a watermark candidate if its own content
//     stream's only meaningful draw call is to a watermark-candidate
//     image.
//   - Only refs that appear on 2+ pages are treated as confirmed
//     watermarks — a one-off small transparent image on a single page is
//     far more likely to be legitimate exam content (a diagram, a stamp
//     that's part of the actual paper) than a distributor's brand mark.
// ---------------------------------------------------------------------

const MAX_WATERMARK_AREA_PX = 60_000;
const MIN_WATERMARK_ASPECT = 2.5; // width / height

function nameOf(dict: PDFDict, key: string): string | undefined {
  const v = dict.get(PDFName.of(key));
  return v ? v.toString().replace(/^\//, "") : undefined;
}

function numberOf(dict: PDFDict, key: string): number | undefined {
  const v = dict.get(PDFName.of(key));
  const n = v ? Number((v as unknown as { asNumber?: () => number }).asNumber?.() ?? NaN) : NaN;
  return Number.isFinite(n) ? n : undefined;
}

/** Safely inflates a FlateDecode stream's bytes; null if it isn't one / fails. */
function tryInflate(stream: PDFRawStream): string | null {
  const filter = nameOf(stream.dict, "Filter");
  if (filter !== "FlateDecode") return null;
  try {
    return inflateSync(Buffer.from(stream.getContents())).toString("latin1");
  } catch {
    return null;
  }
}

/** Looks up a resource dict's /XObject sub-dict name -> PDFRef map. */
function xObjectRefs(context: PDFContext, resources: PDFDict | undefined): Map<string, PDFRef> {
  const out = new Map<string, PDFRef>();
  if (!resources) return out;
  const xobj = resources.lookupMaybe(PDFName.of("XObject"), PDFDict);
  if (!xobj) return out;
  for (const [key, value] of xobj.entries()) {
    const ref = value instanceof PDFRef ? value : context.getObjectRef(value as never);
    if (ref) out.set(key.decodeText(), ref);
  }
  return out;
}

export async function stripKnownWatermarks(pdfBytes: Buffer): Promise<Buffer> {
  const pdfDoc = await PDFDocument.load(pdfBytes, { updateMetadata: false });
  const context = pdfDoc.context;

  // Pass 1a — find every Image XObject matching the watermark shape. Must
  // fully finish before 1b: enumerateIndirectObjects()'s order isn't
  // guaranteed to put an image before the Form that wraps it (in the
  // investigated sample, the Form is object 42 and its image is object
  // 53 — the Form comes first), so a Form's "does this wrap a confirmed
  // watermark image" check can't run in the same pass as building the
  // image set it checks against.
  const watermarkImageRefs = new Set<string>(); // ref.toString() values
  const formCandidates: Array<{ ref: PDFRef; obj: PDFRawStream }> = [];
  for (const [ref, obj] of context.enumerateIndirectObjects()) {
    if (!(obj instanceof PDFRawStream)) continue;
    const subtype = nameOf(obj.dict, "Subtype");
    if (subtype === "Image") {
      const width = numberOf(obj.dict, "Width") ?? 0;
      const height = numberOf(obj.dict, "Height") ?? 0;
      const hasSMask = obj.dict.has(PDFName.of("SMask"));
      const area = width * height;
      const aspect = height > 0 ? width / height : 0;
      if (hasSMask && area > 0 && area <= MAX_WATERMARK_AREA_PX && aspect >= MIN_WATERMARK_ASPECT) {
        watermarkImageRefs.add(ref.toString());
      }
    } else if (subtype === "Form") {
      formCandidates.push({ ref, obj });
    }
  }

  // Pass 1b — now check each Form against the *complete* image set.
  const formToImageRef = new Map<string, string>(); // form ref string -> image ref string
  for (const { ref, obj } of formCandidates) {
    const inflated = tryInflate(obj);
    if (!inflated) continue;
    const doCalls = inflated.match(/\/(\S+)\s+Do\b/g) ?? [];
    if (doCalls.length !== 1) continue; // only forms that draw exactly one thing
    const resources = obj.dict.lookupMaybe(PDFName.of("Resources"), PDFDict);
    const refs = xObjectRefs(context, resources);
    const resourceName = doCalls[0].match(/\/(\S+)\s+Do/)?.[1];
    const imageRef = resourceName ? refs.get(resourceName) : undefined;
    if (imageRef && watermarkImageRefs.has(imageRef.toString())) {
      formToImageRef.set(ref.toString(), imageRef.toString());
    }
  }

  // Candidates this page's content stream should strip Do-calls for:
  // both directly-watermark images and forms that wrap one.
  const candidateRefStrings = new Set<string>([...watermarkImageRefs, ...formToImageRef.keys()]);
  if (candidateRefStrings.size === 0) return pdfBytes; // nothing matched — leave the file untouched

  // Pass 2 — count how many distinct pages actually reference each
  // candidate, so a one-off (more likely real content) isn't touched.
  const pages = pdfDoc.getPages();
  const pageResourceNames: Array<Map<string, string>> = []; // per page: candidate ref string -> resource name used on that page
  const refPageCount = new Map<string, number>();

  for (const page of pages) {
    const resources = page.node.Resources();
    const refs = xObjectRefs(context, resources);
    const namesForThisPage = new Map<string, string>();
    for (const [name, ref] of refs) {
      const refStr = ref.toString();
      if (candidateRefStrings.has(refStr)) {
        namesForThisPage.set(refStr, name);
      }
    }
    pageResourceNames.push(namesForThisPage);
    for (const refStr of namesForThisPage.keys()) {
      refPageCount.set(refStr, (refPageCount.get(refStr) ?? 0) + 1);
    }
  }

  const confirmedRefs = new Set([...refPageCount.entries()].filter(([, count]) => count >= 2).map(([r]) => r));
  if (confirmedRefs.size === 0) return pdfBytes;

  // Pass 3 — for each page, decompress its content stream(s) and strip
  // the specific "q ... cm /Name Do Q" block invoking a confirmed
  // watermark resource, leaving every other draw call (the real page
  // scan) completely untouched.
  let changed = false;
  for (let i = 0; i < pages.length; i++) {
    const namesForThisPage = pageResourceNames[i];
    const namesToStrip = [...namesForThisPage.entries()]
      .filter(([refStr]) => confirmedRefs.has(refStr))
      .map(([, name]) => name);
    if (namesToStrip.length === 0) continue;

    const contents = pages[i].node.Contents();
    const streamObjs: Array<{ ref: PDFRef; stream: PDFRawStream }> = [];
    if (contents instanceof PDFArray) {
      for (let j = 0; j < contents.size(); j++) {
        const ref = contents.get(j);
        if (ref instanceof PDFRef) {
          const obj = context.lookup(ref);
          if (obj instanceof PDFRawStream) streamObjs.push({ ref, stream: obj });
        }
      }
    } else if (contents instanceof PDFStream) {
      const ref = context.getObjectRef(contents);
      if (ref && contents instanceof PDFRawStream) streamObjs.push({ ref, stream: contents });
    }

    for (const { ref, stream } of streamObjs) {
      const inflated = tryInflate(stream);
      if (inflated === null) continue;

      let updated = inflated;
      for (const name of namesToStrip) {
        const escaped = name.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
        // Matches the exact shape confirmed in the sample:
        // "q\n<six numbers> cm\n/Name Do\nQ" — only removes this specific
        // save-transform-draw-restore block for a confirmed watermark
        // resource name, nothing else in the stream.
        const pattern = new RegExp(
          `q\\s*(?:[-\\d.]+\\s+){6}cm\\s*/${escaped}\\s+Do\\s*Q`,
          "g",
        );
        updated = updated.replace(pattern, "");
      }

      if (updated !== inflated) {
        changed = true;
        const recompressed = deflateSync(Buffer.from(updated, "latin1"));
        const newDict = context.obj({ ...Object.fromEntries(stream.dict.entries().map(([k, v]) => [k.decodeText(), v])) }) as PDFDict;
        newDict.set(PDFName.of("Length"), context.obj(recompressed.length));
        const newStream = PDFRawStream.of(newDict, recompressed);
        context.assign(ref, newStream);
      }
    }
  }

  if (!changed) return pdfBytes;
  const savedBytes = await pdfDoc.save();
  return Buffer.from(savedBytes);
}
