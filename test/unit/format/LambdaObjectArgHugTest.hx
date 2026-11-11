package unit.format;

import unit.grammar.haxe.HxWriteFixture;

/**
 * A sole arrow-lambda argument whose body is brace-led — an object literal or a statement block — hugs the call
 * parens, `us.map(u -> {` … `})`, and never breaks after its `->`: under a callParameter cascade that falls to
 * `fillLineWithLeadingBreak`, under one whose `noWrap` rule wins, and under defaults. A non-brace lambda body
 * keeps its layout, and an object-literal body that fits flat on the continuation line opens the call like a
 * sole object-literal argument does.
 */
@:nullSafety(Strict)
final class LambdaObjectArgHugTest extends Test {

	private static final ONE_RULE: String = '{"indentation": {"character": "tab", "tabWidth": 4}, "wrapping": {"maxLineLength": 140, '
		+ '"callParameter": {"defaultWrap": "fillLineWithLeadingBreak", "rules": [{"conditions": [{"cond": "exceedsMaxLineLength", '
		+ '"value": 0}], "type": "noWrap"}]}}}';
	private static final TWO_RULES: String = '{"indentation": {"character": "tab", "tabWidth": 4}, "wrapping": {"maxLineLength": 140, '
		+ '"callParameter": {"defaultWrap": "fillLineWithLeadingBreak", "rules": [{"conditions": [{"cond": "exceedsMaxLineLength", '
		+ '"value": 0}], "type": "noWrap"}, {"conditions": [{"cond": "itemCount <= n", "value": 1}, {"cond": "totalItemLength <= n", '
		+ '"value": 100}], "type": "noWrap"}]}}}';
	private static final DEFAULTS: String = '{"indentation": {"character": "tab", "tabWidth": 4}, "wrapping": {"maxLineLength": 140}}';

	/** Seven fields: the object literal's own cascade commits it to one field per line. */
	private static final COMMITTED: String =
		'var x = us.map(u -> {Id: u.id, Name: u.name, Email: u.email, Phone: u.phone, Address: u.address, Zip: u.zip, A: 1});';

	private static final COMMITTED_HUGGED: String = 'var x = us.map(u -> {\n\t\t\tId: u.id,\n\t\t\tName: u.name,\n\t\t\tEmail: u.email,\n'
		+ '\t\t\tPhone: u.phone,\n\t\t\tAddress: u.address,\n\t\t\tZip: u.zip,\n\t\t\tA: 1\n\t\t});';

	/** Three fields too long for the continuation line: the object literal breaks only because it does not fit. */
	private static final LONG: String = 'var x = us.map(u -> {Iddddddddddddddddddddd: u.iddddddddddddddddddd, Nameeeeeeeeeeeeeeeeee: '
		+ 'u.nameeeeeeeeeeeeeeeeeeeee, Emaaaaaaaaail: u.emaaaaaaaail});';

	private static final LONG_HUGGED: String = 'var x = us.map(u -> {\n\t\t\tIddddddddddddddddddddd: u.iddddddddddddddddddd,\n'
		+ '\t\t\tNameeeeeeeeeeeeeeeeee: u.nameeeeeeeeeeeeeeeeeeeee,\n\t\t\tEmaaaaaaaaail: u.emaaaaaaaail\n\t\t});';
	private static final BLOCK: String = 'var y = us.map(u -> {trace(u); trace(u.name);});';
	private static final BLOCK_HUGGED: String = 'var y = us.map(u -> {\n\t\t\ttrace(u);\n\t\t\ttrace(u.name);\n\t\t});';
	private static final FITTING: String = 'var x = us.map(u -> {Iddddddddddddd: u.iddddddddddddddddddd, Nameeeeeeeeeeeeeeeeee: '
		+ 'u.nameeeeeeeeeeeeeeeeeeeee, Emaaaaaaaaail: u.emaaaaaaaail});';
	private static final FITTING_OPEN: String = 'var x = us.map(\n\t\t\tu -> {Iddddddddddddd: u.iddddddddddddddddddd, '
		+ 'Nameeeeeeeeeeeeeeeeee: u.nameeeeeeeeeeeeeeeeeeeee, Emaaaaaaaaail: u.emaaaaaaaail}\n\t\t);';
	private static final CALL_BODY: String = 'var e = us.map(u -> compute(u.iddddddddddddddddddd, u.nameeeeeeeeeeeeeeeeeeeee, '
		+ 'u.emaaaaaaaail, u.phoneeeeeeeeeeeeeeeeeee, u.zip, u.address));';

	public function new(): Void {
		super();
	}

	@:pin('control')
	@:killer('M-ARROW-BRACE-BODY-NO-HUG')
	public function testCommittedObjectHugsUnderOneRule(): Void {
		Assert.equals(inMethod(COMMITTED_HUGGED), write(ONE_RULE, inMethod(COMMITTED)));
	}

	@:pin('control')
	@:killer('M-ARROW-BRACE-BODY-NO-HUG')
	public function testCommittedObjectHugsUnderTwoRules(): Void {
		Assert.equals(inMethod(COMMITTED_HUGGED), write(TWO_RULES, inMethod(COMMITTED)));
	}

	@:pin('guard')
	public function testCommittedObjectHugsUnderDefaults(): Void {
		Assert.equals(inMethod(COMMITTED_HUGGED), write(DEFAULTS, inMethod(COMMITTED)));
	}

	@:pin('control')
	@:killer('M-ARROW-BRACE-BODY-KEEPS-ARROW-BREAK')
	public function testLongObjectHugsUnderOneRule(): Void {
		Assert.equals(inMethod(LONG_HUGGED), write(ONE_RULE, inMethod(LONG)));
	}

	@:pin('control')
	@:killer('M-ARROW-BRACE-BODY-KEEPS-ARROW-BREAK')
	public function testLongObjectHugsUnderTwoRules(): Void {
		Assert.equals(inMethod(LONG_HUGGED), write(TWO_RULES, inMethod(LONG)));
	}

	@:pin('control')
	@:killer('M-ARROW-BRACE-BODY-KEEPS-ARROW-BREAK')
	public function testLongObjectHugsUnderDefaults(): Void {
		Assert.equals(inMethod(LONG_HUGGED), write(DEFAULTS, inMethod(LONG)));
	}

	@:pin('control')
	@:killer('M-ARROW-BRACE-BODY-NO-HUG')
	public function testBlockBodyHugsUnderOneRule(): Void {
		Assert.equals(inMethod(BLOCK_HUGGED), write(ONE_RULE, inMethod(BLOCK)));
	}

	@:pin('guard')
	public function testFittingObjectOpensFlat(): Void {
		Assert.equals(inMethod(FITTING_OPEN), write(ONE_RULE, inMethod(FITTING)));
	}

	@:pin('guard')
	public function testCallBodyKeepsItsLayout(): Void {
		Assert.equals(
			inMethod(
				'var e = us.map(\n\t\t\tu -> compute(u.iddddddddddddddddddd, u.nameeeeeeeeeeeeeeeeeeeee, u.emaaaaaaaail, '
				+ 'u.phoneeeeeeeeeeeeeeeeeee, u.zip, u.address)\n\t\t);'
			),
			write(ONE_RULE, inMethod(CALL_BODY))
		);
		Assert.equals(
			inMethod(
				'var e = us.map(u ->\n\t\t\tcompute(u.iddddddddddddddddddd, u.nameeeeeeeeeeeeeeeeeeeee, u.emaaaaaaaail, '
				+ 'u.phoneeeeeeeeeeeeeeeeeee, u.zip, u.address)\n\t\t);'
			),
			write(DEFAULTS, inMethod(CALL_BODY))
		);
	}

	private static function write(config: String, src: String): String {
		return HxWriteFixture.triviaWrite(src, config);
	}

	private static function inMethod(statements: String): String {
		return 'class C {\n\tfunction test() {\n\t\t$statements\n\t}\n}';
	}

}
