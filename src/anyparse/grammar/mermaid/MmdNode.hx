package anyparse.grammar.mermaid;

/**
 * A node: an id, then its shape, class and data as postfix operators, so each hugs the id it
 * follows (`A([Start]):::green`). The shapes are Mermaid's bracket pairs, longest opener first;
 * the two slanted openers `[/` and `[\` each close two ways, which their body enums tell apart.
 */
@:peg
enum MmdNode {
	@:postfix('(((', ')))')
	DoubleCircle(vertex: MmdNode, text: MmdLabel);

	@:postfix('((', '))')
	Circle(vertex: MmdNode, text: MmdLabel);

	@:postfix('([', '])')
	Stadium(vertex: MmdNode, text: MmdLabel);

	@:postfix('(', ')')
	Round(vertex: MmdNode, text: MmdLabel);

	@:postfix('[[', ']]')
	Subroutine(vertex: MmdNode, text: MmdLabel);

	@:postfix('[(', ')]')
	Cylinder(vertex: MmdNode, text: MmdLabel);

	@:postfix('[/')
	Slash(vertex: MmdNode, body: MmdSlashBody);

	@:postfix('[\\')
	Backslash(vertex: MmdNode, body: MmdBackslashBody);

	@:postfix('[', ']')
	Rect(vertex: MmdNode, text: MmdLabel);

	@:postfix('{{', '}}')
	Hexagon(vertex: MmdNode, text: MmdLabel);

	@:postfix('{', '}')
	Diamond(vertex: MmdNode, text: MmdLabel);

	@:postfix('>', ']')
	Asymmetric(vertex: MmdNode, text: MmdLabel);

	/** `A@{ shape: … }`, the data block of the newer shape syntax. */
	@:postfix('@{', '}')
	Data(vertex: MmdNode, data: MmdShapeDataLit);

	@:postfix(':::')
	Classed(vertex: MmdNode, className: MmdIdLit);

	Id(id: MmdIdLit);
}
