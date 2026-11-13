package unit.format;

import unit.grammar.haxe.HxWriteFixture;

/**
 * A brace-led arrow body is its own wrap point wherever the arrow is the LAST item of a list, not only when it is
 * a sole call argument: the body stays on the `->` line, and the list hugs or breaks before the arrow as it does for
 * a `{`-led last item — the last argument of a multi-argument call, the sole or last element of an array literal, the
 * last field value of an object literal. A non-brace arrow body keeps its layout.
 */
@:nullSafety(Strict)
final class ArrowBraceBodyLastItemTest extends Test {

	private static final TWO_RULES: String = '{"indentation": {"character": "tab", "tabWidth": 4}, "wrapping": {"maxLineLength": 140, '
		+ '"callParameter": {"defaultWrap": "fillLineWithLeadingBreak", "rules": [{"conditions": [{"cond": "exceedsMaxLineLength", '
		+ '"value": 0}], "type": "noWrap"}, {"conditions": [{"cond": "itemCount <= n", "value": 1}, {"cond": "totalItemLength <= n", '
		+ '"value": 100}], "type": "noWrap"}]}}}';
	private static final DEFAULTS: String = '{"indentation": {"character": "tab", "tabWidth": 4}, "wrapping": {"maxLineLength": 140}}';
	private static final FIELDS: String =
		'Iddddddddddddddddddddd: u.iddddddddddddddddddd, Nameeeeeeeeeeeeeeeeee: u.nameeeeeeeeeeeeeeeeeeeee, Emaaaaaaaaail: u.emaaaaaaaail';
	private static final MULTI_ARG: String = 'var q = foo(0, u -> {$FIELDS});';
	private static final MULTI_ARG_HUGGED: String = 'var q = foo(0, u -> {\n\t\t\tIddddddddddddddddddddd: u.iddddddddddddddddddd,\n'
		+ '\t\t\tNameeeeeeeeeeeeeeeeee: u.nameeeeeeeeeeeeeeeeeeeee,\n\t\t\tEmaaaaaaaaail: u.emaaaaaaaail\n\t\t});';
	private static final ARRAY: String = 'var p = [u -> {$FIELDS}];';
	private static final ARRAY_BROKEN: String = 'var p = [\n\t\t\tu -> {\n\t\t\t\tIddddddddddddddddddddd: u.iddddddddddddddddddd,\n'
		+ '\t\t\t\tNameeeeeeeeeeeeeeeeee: u.nameeeeeeeeeeeeeeeeeeeee,\n\t\t\t\tEmaaaaaaaaail: u.emaaaaaaaail\n\t\t\t}\n\t\t];';
	private static final ARRAY_LAST: String = 'var b = [aaaa, bbbb, u -> {$FIELDS}];';
	private static final ARRAY_LAST_BROKEN: String = 'var b = [\n\t\t\taaaa,\n\t\t\tbbbb,\n\t\t\tu -> {\n'
		+ '\t\t\t\tIddddddddddddddddddddd: u.iddddddddddddddddddd,\n\t\t\t\tNameeeeeeeeeeeeeeeeee: u.nameeeeeeeeeeeeeeeeeeeee,\n'
		+ '\t\t\t\tEmaaaaaaaaail: u.emaaaaaaaail\n\t\t\t}\n\t\t];';
	private static final OBJECT_FIELD: String = 'var c = {a: 1, bbbbbbbbbbbbbbbbbbbb: () -> {'
		+ 'Iddddddddddddddddddddd: u.iddddddddddddddddddd, Nameeeeeeeeeeeeeeeeee: u.nameeeeeeeeeeeeeeeeeeeee, Emaaail: 1}};';
	private static final OBJECT_FIELD_BROKEN: String = 'var c = {\n\t\t\ta: 1,\n\t\t\tbbbbbbbbbbbbbbbbbbbb: () -> {\n'
		+ '\t\t\t\tIddddddddddddddddddddd: u.iddddddddddddddddddd,\n\t\t\t\tNameeeeeeeeeeeeeeeeee: u.nameeeeeeeeeeeeeeeeeeeee,\n'
		+ '\t\t\t\tEmaaail: 1\n\t\t\t}\n\t\t};';
	private static final BESIDE_BROKEN: String = 'always(() -> for (dir in [cache, first.dir, first.probe, second.dir, second.probe, '
		+ 'third.dir, third.probe, edited.dir, edited.probe, other]) removeDir(dir), () -> {trace(1); trace(2);});';
	private static final BESIDE_BROKEN_GLUED: String = 'always(() -> for (dir in [\n\t\t\tcache,\n\t\t\tfirst.dir,\n\t\t\tfirst.probe,\n'
		+ '\t\t\tsecond.dir,\n\t\t\tsecond.probe,\n\t\t\tthird.dir,\n\t\t\tthird.probe,\n\t\t\tedited.dir,\n\t\t\tedited.probe,\n'
		+ '\t\t\tother\n\t\t]) removeDir(dir), () -> {\n\t\t\ttrace(1);\n\t\t\ttrace(2);\n\t\t});';
	private static final PLAIN_BODY: String = 'var t = foo(0, u -> u.iddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd '
		+ '+ u.nameeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee);';

	public function new(): Void {
		super();
	}

	@:pin('control')
	@:killer('M-ARROW-BRACE-LAST-NOT-COLLECTION-LED')
	public function testMultiArgLastArrowHugsUnderRules(): Void {
		Assert.equals(inMethod(MULTI_ARG_HUGGED), write(TWO_RULES, inMethod(MULTI_ARG)));
	}

	@:pin('control')
	@:killer('M-ARROW-BRACE-LAST-NOT-COLLECTION-LED')
	public function testMultiArgLastArrowHugsUnderDefaults(): Void {
		Assert.equals(inMethod(MULTI_ARG_HUGGED), write(DEFAULTS, inMethod(MULTI_ARG)));
	}

	@:pin('control')
	@:killer('M-ARROW-BRACE-BODY-NO-HUG')
	public function testArraySoleArrowKeepsBodyOnArrowLineUnderRules(): Void {
		Assert.equals(inMethod(ARRAY_BROKEN), write(TWO_RULES, inMethod(ARRAY)));
	}

	@:pin('control')
	@:killer('M-ARROW-BRACE-BODY-NO-HUG')
	public function testArraySoleArrowKeepsBodyOnArrowLineUnderDefaults(): Void {
		Assert.equals(inMethod(ARRAY_BROKEN), write(DEFAULTS, inMethod(ARRAY)));
	}

	@:pin('control')
	@:killer('M-ARROW-BRACE-BODY-NO-HUG')
	public function testArrayLastArrowKeepsBodyOnArrowLineUnderRules(): Void {
		Assert.equals(inMethod(ARRAY_LAST_BROKEN), write(TWO_RULES, inMethod(ARRAY_LAST)));
	}

	@:pin('control')
	@:killer('M-ARROW-BRACE-BODY-NO-HUG')
	public function testArrayLastArrowKeepsBodyOnArrowLineUnderDefaults(): Void {
		Assert.equals(inMethod(ARRAY_LAST_BROKEN), write(DEFAULTS, inMethod(ARRAY_LAST)));
	}

	@:pin('control')
	@:killer('M-ARROW-BRACE-BODY-NO-HUG')
	public function testObjectFieldArrowKeepsBodyOnArrowLineUnderRules(): Void {
		Assert.equals(inMethod(OBJECT_FIELD_BROKEN), write(TWO_RULES, inMethod(OBJECT_FIELD)));
	}

	@:pin('control')
	@:killer('M-ARROW-BRACE-BODY-NO-HUG')
	public function testObjectFieldArrowKeepsBodyOnArrowLineUnderDefaults(): Void {
		Assert.equals(inMethod(OBJECT_FIELD_BROKEN), write(DEFAULTS, inMethod(OBJECT_FIELD)));
	}

	/** The other argument breaks too, so only the block-lambda glue keeps the paren closed. */
	@:pin('control')
	@:killer('M-ARROW-BRACE-HARDLINE-LOSES-BLOCK-GLUE')
	public function testBlockBodyBesideBreakingArgKeepsBlockGlue(): Void {
		Assert.equals(inMethod(BESIDE_BROKEN_GLUED), write(TWO_RULES, inMethod(BESIDE_BROKEN)));
	}

	@:pin('guard')
	public function testPlainArrowBodyKeepsItsLayout(): Void {
		Assert.equals(
			inMethod(
				'var t = foo(\n\t\t\t0,\n\t\t\tu -> u.iddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd '
				+ '+ u.nameeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee\n\t\t);'
			),
			write(TWO_RULES, inMethod(PLAIN_BODY))
		);
		Assert.equals(
			inMethod(
				'var t = foo(0,\n\t\t\tu -> u.iddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd '
				+ '+ u.nameeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee);'
			),
			write(DEFAULTS, inMethod(PLAIN_BODY))
		);
	}

	private static function write(config: String, src: String): String {
		return HxWriteFixture.triviaWrite(src, config);
	}

	private static function inMethod(statements: String): String {
		return 'class C {\n\tfunction test() {\n\t\t$statements\n\t}\n}';
	}

}
