package unit;

import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.QueryNode;
import anyparse.runtime.Span;
import utest.Assert;
import utest.Test;
#if (sys || nodejs)
import sys.io.File;
#end

/**
 * No anonymous structure the static-target build compiles is wider than a JVM constructor can take.
 *
 * `--jvm` lowers a structure typedef, an inline structure type and each object literal's field set
 * to a class whose constructor takes one argument per field, and a JVM method signature holds at
 * most 255 argument slots — `this` takes one, a `Float` or an `Int64` two. The build stays green
 * past the limit; the class is rejected only when it is LOADED, so the jar dies at run time with
 * `ClassFormatError: Too many arguments in method signature`, and the js runner never meets it.
 *
 * The sweep reads the slots off the source. What it cannot see is a structure a macro assembles,
 * which only the portability probe reaches (docs/testing.md § "The core stays target-independent").
 */
@:nullSafety(Strict)
final class JvmStructureWidthTest extends Test {

	/** A JVM method descriptor's argument-slot ceiling, the receiver included. */
	private static inline final SLOT_LIMIT: Int = 255;

	/** The roots `tools/jvm-portability.hxml` compiles from. */
	private static final ROOTS: Array<String> = ['src', 'tools'];

	/**
	 * Every structure under the probe's roots fits a JVM constructor.
	 *
	 * A `guard`: nothing in the engine decides it, so no source cut kills it. It goes red the day a
	 * structure grows past the limit — a grammar vocabulary that is a typedef again, or a new one.
	 */
	@:pin('guard')
	public function testNoStructureInTheCompiledTreeOutgrowsAJvmConstructor(): Void {
		#if (sys || nodejs)
		final paths: Array<String> = [for (root in ROOTS) for (path in SourceTree.collect(root)) path];
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		final sources: Map<String, String> = [];
		final trees: Map<String, QueryNode> = [];
		final unread: Array<String> = [];
		for (path in paths) {
			final source: String = File.getContent(path);
			try {
				trees[path] = plugin.parseFile(source);
				sources[path] = source;
			} catch (e: haxe.Exception) {
				unread.push('$path: ${e.message}');
			}
		}
		final named: Map<String, Int> = [];
		for (path => tree in trees) collectTypedefSlots(tree, sources[path] ?? '', named);
		final over: Array<String> = [];
		for (path in paths) {
			final tree: Null<QueryNode> = trees[path];
			if (tree != null) for (line in overflows(tree, sources[path] ?? '', named)) over.push('$path:$line');
		}
		Assert.isTrue(paths.length > 0, 'the probe roots must contain .hx files');
		Assert.same([], unread, 'a file this sweep cannot parse is a file it cannot vouch for:\n  ' + unread.join('\n  '));
		Assert.same(
			[], over,
			'a structure past the JVM argument-slot limit — make it a class, or nest a group of its fields:\n  ' + over.join('\n  ')
		);
		#else
		Assert.fail('this gate is compiled out on the current target, so nothing enforces the width it checks');
		#end
	}

	/**
	 * The sweep reports a structure one slot past the limit and passes one at it, counting a `Float`
	 * as two slots and a `> Base` extension as the fields it copies.
	 */
	@:pin('guard')
	public function testAStructureOneSlotOverTheLimitIsReported(): Void {
		final atLimit: String = 'typedef AtLimit = { ${fields('a', 'Int', SLOT_LIMIT - 1)} };\n';
		final overLimit: String = 'typedef OverLimit = { ${fields('b', 'Int', SLOT_LIMIT)} };\n';
		final doubles: String = 'typedef Doubles = { ${fields('d', 'Float', 128)} };\n';
		final extended: String = 'typedef Extended = { > AtLimit, extra: Int };\n';
		final literal: String = 'class C { static function f() { return { ${values('v', SLOT_LIMIT)} }; } }\n';
		Assert.same([], sweep(atLimit), '254 fields and the receiver fill the 255 slots exactly');
		Assert.same(['1: OverLimit 256 slots'], sweep(overLimit));
		Assert.same(['1: Doubles 257 slots'], sweep(doubles), 'a Float takes two slots');
		Assert.same(['2: Extended 256 slots'], sweep(atLimit + extended), 'an extension copies its base fields');
		Assert.same(['1: object literal 256 slots'], sweep(literal));
	}

	/** The overflow lines `overflows` reports for one in-memory module. */
	private static function sweep(source: String): Array<String> {
		final tree: QueryNode = new HaxeQueryPlugin().parseFile(source);
		final named: Map<String, Int> = [];
		collectTypedefSlots(tree, source, named);
		return overflows(tree, source, named);
	}

	/** `count` structure fields `<prefix><i>: <type>`, comma-separated. */
	private static function fields(prefix: String, type: String, count: Int): String {
		return [for (i in 0...count) '$prefix$i: $type'].join(', ');
	}

	/** `count` object-literal fields `<prefix><i>: 0`, comma-separated. */
	private static function values(prefix: String, count: Int): String {
		return [for (i in 0...count) '$prefix$i: 0'].join(', ');
	}

	/** Record the constructor slots of every structure typedef in `tree` by its simple name. */
	private static function collectTypedefSlots(tree: QueryNode, source: String, into: Map<String, Int>): Void {
		final name: Null<String> = tree.name;
		if (tree.kind == 'TypedefDecl' && name != null) {
			final body: Null<QueryNode> = tree.children.filter(child -> child.kind == 'Anon')[0];
			if (body != null) into[name] = fieldSlots(body, source, into);
		}
		for (child in tree.children) collectTypedefSlots(child, source, into);
	}

	/**
	 * `<line>: <owner> <slots> slots` for each structure in `tree` past `SLOT_LIMIT`, the receiver
	 * included; an object literal's fields count one slot each, its value types being unwritten.
	 */
	private static function overflows(tree: QueryNode, source: String, named: Map<String, Int>): Array<String> {
		final out: Array<String> = [];
		// A typedef carries its structure twice, as its child and as its `type` slot.
		final counted: Map<Int, Bool> = [];
		function visit(node: QueryNode, owner: String): Void {
			if (node.kind == 'Anon' || node.kind == 'ObjectLit') {
				final at: Int = node.span?.from ?? -1;
				if (counted.exists(at)) return;
				counted[at] = true;
			}
			final slots: Int = switch node.kind {
				case 'Anon': 1 + fieldSlots(node, source, named);
				case 'ObjectLit': 1 + node.children.filter(child -> child.kind == 'Field').length;
				case _: 0;
			}
			if (slots > SLOT_LIMIT) out.push('${lineOf(node.span, source)}: $owner $slots slots');
			final next: String = node.kind == 'TypedefDecl' ? node.name ?? 'typedef' : 'object literal';
			for (child in node.children) visit(child, next);
			final type: Null<QueryNode> = node.type;
			if (type != null) visit(type, 'structure type');
		}
		visit(tree, 'object literal');
		return out;
	}

	/**
	 * The constructor slots of a structure body's fields: two for a `Float` or an `Int64`, one for any
	 * other; a `> Base` adds the base's own, every `#if` branch counts. Excludes the receiver.
	 */
	private static function fieldSlots(body: QueryNode, source: String, named: Map<String, Int>): Int {
		var slots: Int = 0;
		for (child in body.children) switch child.kind {
			case 'VarField', 'FinalField', 'FnField', 'Required', 'Optional':
				slots += isWide(child.span, source) ? 2 : 1;
			case 'ExtendsField':
				final base: Null<String> = child.name;
				if (base != null) slots += named[base] ?? 0;
			case 'Conditional':
				slots += fieldSlots(child, source, named);
			case _:
		}
		return slots;
	}

	/** Whether the field at `span` is declared `Float` or `Int64` — a two-slot JVM primitive. */
	private static function isWide(span: Null<Span>, source: String): Bool {
		return span != null && ~/:\s*(haxe\.)?(Float|Int64)\s*[;,]?\s*$/.match(source.substring(span.from, span.to));
	}

	/** The 1-based line `span` starts on, 0 for a node without one. */
	private static function lineOf(span: Null<Span>, source: String): Int {
		return span == null ? 0 : span.lineCol(source).line;
	}

}
