package anyparse.grammar.haxe;

/**
 * One piece of a condition group's interior. A quote or a block comment that does not close ends the group unbalanced,
 * since no piece reads its opening byte as text. A line comment is text: Haxe refuses one inside a condition group.
 */
@:peg
enum HxPpCondGroupItem {
	Inner(group: HxPpCondGroup);
	InnerQuoted(text: HxPpCondQuoted);
	Comment(text: HxPpCondComment);
	Text(text: HxPpCondText);
}
