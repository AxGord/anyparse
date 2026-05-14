package unit;

import anyparse.format.text.JsonFormat;
import utest.Assert;
import utest.Test;

/**
 * Pilot for the recursive-typedef JSON schema path that `apq ast`
 * plans to use for its `--json` output.
 *
 * Goal: confirm that `@:peg @:schema(JsonFormat) typedef T` with a
 * self-referential `Array<T>` field round-trips through both the
 * macro-generated parser and writer.
 *
 * If this lands green, the production `AstNodeJson` schema can be
 * built the same way and `src/anyparse/query/format/Json.hx`'s manual
 * StringBuf code goes away.
 */
@:nullSafety(Strict)
class ApqJsonSchemaProbe extends Test {

	public function new():Void {
		super();
	}

	public function testParseLeaf():Void {
		final node:ApqProbeNode = ApqProbeNodeParser.parse('{"kind":"leaf","children":[]}');
		Assert.equals('leaf', node.kind);
		Assert.equals(0, node.children.length);
	}

	public function testParseRecursive():Void {
		final src:String = '{"kind":"root","children":[{"kind":"a","children":[]},{"kind":"b","children":[{"kind":"deep","children":[]}]}]}';
		final node:ApqProbeNode = ApqProbeNodeParser.parse(src);
		Assert.equals('root', node.kind);
		Assert.equals(2, node.children.length);
		Assert.equals('a', node.children[0].kind);
		Assert.equals('b', node.children[1].kind);
		Assert.equals(1, node.children[1].children.length);
		Assert.equals('deep', node.children[1].children[0].kind);
	}

	public function testWriteLeaf():Void {
		final node:ApqProbeNode = {kind: 'leaf', children: []};
		final out:String = ApqProbeNodeWriter.write(node, JsonFormat.instance.defaultWriteOptions);
		Assert.notNull(out);
		Assert.isTrue(out.length > 0);
		final back:ApqProbeNode = ApqProbeNodeParser.parse(out);
		Assert.equals('leaf', back.kind);
		Assert.equals(0, back.children.length);
	}

	public function testWriteRecursiveRoundTrip():Void {
		final src:String = '{"kind":"root","children":[{"kind":"a","children":[]},{"kind":"b","children":[{"kind":"deep","children":[]}]}]}';
		final parsed:ApqProbeNode = ApqProbeNodeParser.parse(src);
		final out:String = ApqProbeNodeWriter.write(parsed, JsonFormat.instance.defaultWriteOptions);
		final back:ApqProbeNode = ApqProbeNodeParser.parse(out);
		Assert.equals('root', back.kind);
		Assert.equals(2, back.children.length);
		Assert.equals('a', back.children[0].kind);
		Assert.equals('b', back.children[1].kind);
		Assert.equals('deep', back.children[1].children[0].kind);
	}

	public function testParseOptionalAbsent():Void {
		final node:ApqProbeNode = ApqProbeNodeParser.parse('{"kind":"leaf","children":[]}');
		Assert.isNull(node.name);
	}

	public function testParseOptionalPresent():Void {
		final node:ApqProbeNode = ApqProbeNodeParser.parse('{"kind":"FnDecl","name":"foo","children":[]}');
		Assert.equals('foo', node.name);
	}

	public function testWriteOptionalAbsentOmitsKey():Void {
		final node:ApqProbeNode = {kind: 'leaf', children: []};
		final out:String = ApqProbeNodeWriter.write(node, JsonFormat.instance.defaultWriteOptions);
		Assert.isFalse(out.indexOf('"name"') >= 0, '"name" key must be omitted when value is null, got: $out');
		final back:ApqProbeNode = ApqProbeNodeParser.parse(out);
		Assert.isNull(back.name);
	}

	public function testWriteOptionalPresentEmitsKey():Void {
		final node:ApqProbeNode = {kind: 'FnDecl', name: 'foo', children: []};
		final out:String = ApqProbeNodeWriter.write(node, JsonFormat.instance.defaultWriteOptions);
		Assert.isTrue(out.indexOf('"name"') >= 0, '"name" key must be present, got: $out');
		final back:ApqProbeNode = ApqProbeNodeParser.parse(out);
		Assert.equals('foo', back.name);
	}

	public function testRoundTripMixedOptional():Void {
		final src:String = '{"kind":"root","children":[{"kind":"a","name":"alpha","children":[]},{"kind":"b","children":[{"kind":"deep","name":"d","children":[]}]}]}';
		final parsed:ApqProbeNode = ApqProbeNodeParser.parse(src);
		final out:String = ApqProbeNodeWriter.write(parsed, JsonFormat.instance.defaultWriteOptions);
		final back:ApqProbeNode = ApqProbeNodeParser.parse(out);
		Assert.equals('root', back.kind);
		Assert.isNull(back.name);
		Assert.equals('alpha', back.children[0].name);
		Assert.isNull(back.children[1].name);
		Assert.equals('d', back.children[1].children[0].name);
	}
}
