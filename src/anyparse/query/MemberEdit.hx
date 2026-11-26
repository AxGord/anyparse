package anyparse.query;

import anyparse.runtime.Span;

/**
 * The edit that adds one member to a type body, or, with no edit, why it cannot be added.
 */
typedef MemberEdit = { edit: Null<{ span: Span, text: String }>, refusal: String }
