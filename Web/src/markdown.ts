import { marked } from "marked";
import DOMPurify from "dompurify";
export function preview(text: string) {
  return DOMPurify.sanitize(marked.parse(text, { async: false }), {
    ALLOWED_TAGS: [
      "p",
      "h1",
      "h2",
      "h3",
      "h4",
      "h5",
      "h6",
      "ul",
      "ol",
      "li",
      "em",
      "strong",
      "del",
      "blockquote",
      "pre",
      "code",
      "a",
      "br",
      "hr",
      "table",
      "thead",
      "tbody",
      "td",
      "th",
    ],
    ALLOWED_ATTR: ["href", "title"],
    ALLOWED_URI_REGEXP: /^(?:https?:\/\/|mailto:|#)/i,
  });
}
