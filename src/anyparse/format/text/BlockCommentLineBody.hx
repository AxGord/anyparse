package anyparse.format.text;

/**
 * Terminal for one line's body inside a block-comment, captured
 * verbatim from the first non-ws character on the line up to the
 * next newline or the wrap close `*\/`.
 *
 * Regex `(?:(?!\*\/)[^\n])*` — match any non-newline character that
 * does not start a `*\/` close delimiter at this position. Lookahead
 * accepts wrap-adjacent `*` runs (`*` after `/**` open absorbed into
 * line[0].body; `*` before `**\/` close absorbed into line[N].body),
 * since the `*` is followed by another `*` rather than `/`.
 */
@:re('(?:(?!\\*/)[^\\n])*')
@:rawString
abstract BlockCommentLineBody(String) from String to String {}
