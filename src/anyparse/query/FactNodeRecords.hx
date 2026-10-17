package anyparse.query;

import anyparse.query.CompilerFacts.ArgumentFact;
import anyparse.query.CompilerFacts.CallFact;
import anyparse.query.CompilerFacts.ElementWriteFact;
import anyparse.query.CompilerFacts.FactNode;
import anyparse.query.CompilerFacts.FactPos;
import anyparse.query.CompilerFacts.FieldFact;
import anyparse.query.CompilerFacts.FlowFact;
import anyparse.query.CompilerFacts.HandFact;
import anyparse.query.CompilerFacts.InstantiationFact;
import anyparse.query.CompilerFacts.IterationFact;
import anyparse.query.CompilerFacts.LocalReadFact;
import anyparse.query.CompilerFacts.NativeFact;
import anyparse.query.CompilerFacts.NewFact;
import anyparse.query.CompilerFacts.ParamUse;
import anyparse.query.CompilerFacts.ReflectionFact;
import anyparse.query.CompilerFacts.SpliceFact;
import anyparse.query.CompilerFacts.StringFact;
import anyparse.query.CompilerFacts.VarFact;
import anyparse.runtime.Span;
import haxe.Json;

using Lambda;
using StringTools;

/**
 * A facts file's NODE record (`{"k":"node",…}`, written by `TypedFactsMacro`) and its decoding into the
 * `FactNode` the table answers with: the empty node one record heads, the facts of every family it
 * holds, the join of a further configuration's record of the same node, and the splices its inlined
 * calls brought in.
 *
 * Its own module rather than more of `CompilerFacts` because it is the record SCHEMA and a set of
 * pure functions over it: nothing here reads the table, the positions arrive already placed
 * (`place`), and identity across configurations arrives as `fresh`. The table decides which lines
 * make a node and where their positions land; this decides what a record says.
 */
@:nullSafety(Strict)
final class FactNodeRecords {

	/** The access of a call of a method the compiler spliced in (`CallFact.access`). */
	private static inline final INLINED: String = 'inlined';

	/** The node `id` as `record` heads it, at `at`, with no facts yet. */
	public static function emptyNode(id: String, record: NodeRecord, at: FactPos): FactNode {
		return {
			id: id,
			kind: record.kind,
			owner: record.owner,
			isStatic: record.s ?? false,
			signature: record.t,
			name: record.name,
			at: at,
			incomplete: (record.inc ?? []).copy(),
			generated: record.gen ?? false,
			inlinedFrom: record.inl,
			overloadIndex: record.ov ?? 0,
			params: [for (p in record.params ?? []) { name: p.n, type: p.t }],
			keptParams: (record.pk ?? []).copy(),
			paramUses: paramUsesOf(record),
			variants: [],
			calls: [],
			news: [],
			fields: [],
			elementWrites: [],
			flows: [],
			handed: [],
			instantiations: [],
			strings: [],
			iterations: [],
			reflection: [],
			natives: [],
			vars: [],
			reads: [],
			fns: [],
			splices: [],
			expansions: []
		};
	}

	/**
	 * Join a further configuration's `record` into the node an earlier one made: a parameter is kept only where
	 * every configuration keeps it.
	 */
	public static function joinConfiguration(node: FactNode, record: NodeRecord): Void {
		for (i in node.keptParams.copy()) if (!(record.pk ?? []).contains(i)) node.keptParams.remove(i);
		node.paramUses = joinedParamUses(node.paramUses, paramUsesOf(record));
	}

	/** Add the facts of every family `record` holds to `node`, each at the position `place` reads and only when `fresh`. */
	public static function collectFacts(
		id: String, node: FactNode, record: NodeRecord, place: (Null<Array<Int>>) -> Null<FactPos>, fresh: (String, Any, FactPos) -> Bool
	): Void {
		FactMerge.collect(
			record.calls, c -> place(c.p), fresh.bind('call'), (c, where) -> ({
				target: c.t,
				access: c.a,
				receiver: c.r,
				receiverAt: place(c.rp),
				result: c.rt,
				at: where,
				signature: c.sig,
				site: place(c.s),
				body: place(c.d),
				operand: c.o,
				operandExact: c.x == true
			}: CallFact),
			node.calls
		);
		FactMerge.collect(
			record.news, x -> place(x.p), fresh.bind('new'), (x, where) -> ({
				type: x.t,
				instance: x.ty,
				at: where,
				generic: x.gb
			}: NewFact),
			node.news
		);
		FactMerge.collect(
			record.fields, f -> place(f.p), fresh.bind('field'), (f, where) -> ({
				owner: f.o,
				field: f.f,
				access: f.a,
				receiver: f.r,
				type: f.t,
				write: f.w ?? false,
				at: where,
				use: f.u,
				method: f.m,
				fresh: f.fresh ?? false,
				held: f.h ?? false,
				argument: argumentOf(f)
			}: FieldFact),
			node.fields
		);
		FactMerge.collect(
			record.elems, x -> place(x.p), fresh.bind('elem'),
			(x, where) -> ({receiver: x.r, receiverAt: place(x.rp), at: where }: ElementWriteFact), node.elementWrites
		);
		FactMerge.collect(
			record.flows, f -> place(f.p), fresh.bind('flow'), (f, where) -> ({
				from: f.s,
				to: f.d,
				via: f.c,
				at: where,
				exact: f.x == true
			}: FlowFact),
			node.flows
		);
		FactMerge.collect(
			record.hands, h -> place(h.p), fresh.bind('hand'), (h, where) -> ({
				target: h.t,
				from: h.s,
				to: h.d,
				at: where
			}: HandFact),
			node.handed
		);
		FactMerge.collect(
			record.gens, x -> place(x.p), fresh.bind('gen'), (x, where) -> ({declared: x.d, applied: x.s, at: where }: InstantiationFact),
			node.instantiations
		);
		FactMerge.collect(
			record.strs, s -> place(s.p), fresh.bind('str'), (s, where) -> ({operand: s.o, at: where, exact: s.x == true }: StringFact),
			node.strings
		);
		FactMerge.collect(
			record.iters, i -> place(i.p), fresh.bind('iter'), (i, where) -> ({binder: i.v, iterated: i.i, at: where }: IterationFact),
			node.iterations
		);
		FactMerge.collect(
			record.refl, r -> place(r.p), fresh.bind('refl'), (r, where) -> ({
				target: r.t,
				name: r.n,
				memberName: r.m,
				typeArgument: r.c,
				isValue: r.v ?? false,
				at: where,
				receiver: r.r,
				receiverExact: r.x == true,
				receiverSelf: r.h == true,
				receiverFresh: r.o == true,
				holder: id
			}: ReflectionFact),
			node.reflection
		);
		FactMerge.collect(
			record.native, n -> place(n.p), fresh.bind('native'), (n, where) -> ({
				kind: n.w,
				name: n.n,
				at: where,
				code: n.c,
				computed: n.cc == true,
				handed: n.h ?? [],
				holder: id
			}: NativeFact),
			node.natives
		);
		FactMerge.collect(
			record.vars, v -> place(v.p), fresh.bind('var'), (v, where) -> ({name: v.n, type: v.t, at: where }: VarFact), node.vars
		);
		FactMerge.collect(
			record.reads, r -> place([for (i in 0...r.length - 1) (r[i]: Int)]), fresh.bind('read'), (r, where) -> ({
				type: (r[r.length - 1]: String),
				at: where
			}: LocalReadFact),
			node.reads
		);
	}

	/** Add the macro expansions `record` holds to `node`: each whose root, anchor and declaration all place, once per root. */
	public static function collectExpansions(
		node: FactNode, record: NodeRecord, place: (Null<Array<Int>>) -> Null<FactPos>, fresh: (String, Any, FactPos) -> Bool
	): Void {
		for (x in record.exps ?? []) {
			final root: Null<FactPos> = place(x.p);
			final anchor: Null<FactPos> = place(x.a);
			final declared: Null<FactPos> = place(x.d);
			if (root == null || anchor == null || (x.d != null && declared == null)) continue;
			final written: FactPos = anchor;
			// the root tells one expansion from another, and no question asks it
			if (fresh('exp', x, root)) node.expansions.push({ expander: x.t, anchor: written, declared: declared });
		}
	}

	/** The parameter `use` hands its value to (`FieldFact.argument`), or null for any other use. */
	private static function argumentOf(use: UseRecord): Null<ArgumentFact> {
		final target: Null<String> = use.ag;
		final access: Null<String> = use.aa;
		final index: Null<Int> = use.ai;
		return target == null || access == null || index == null ? null : { target: target, access: access, index: index };
	}

	/** The uses `record` gives each parameter of its node (`FactNode.paramUses`), or null when it records none. */
	private static function paramUsesOf(record: NodeRecord): Null<Array<Array<ParamUse>>> {
		final recorded: Null<Array<Array<UseRecord>>> = record.pu;
		if (recorded == null || recorded.length != (record.params ?? []).length) return null;
		return [
			for (uses in recorded) [for (u in uses) { use: u.u ?? '', method: u.m, argument: argumentOf(u) }]
		];
	}

	/** The uses `known` and `more` give a node's parameters, joined per parameter; null when either is, or they disagree on the count. */
	private static function joinedParamUses(
		known: Null<Array<Array<ParamUse>>>, more: Null<Array<Array<ParamUse>>>
	): Null<Array<Array<ParamUse>>> {
		if (known == null || more == null) return null;
		final added: Array<Array<ParamUse>> = more;
		if (known.length != added.length) return null;
		for (i in 0...known.length) {
			final into: Array<ParamUse> = known[i];
			for (u in added[i]) if (!into.exists(k -> Json.stringify(k) == Json.stringify(u))) into.push(u);
		}
		return known;
	}

	/** The bodies the `inlined` calls of `node` spliced in, one per declared range with every site a call of it ran at. */
	public static function collectSplices(node: Null<FactNode>): Void {
		if (node == null) return;
		for (c in node.calls) {
			final body: Null<FactPos> = c.body;
			final site: Null<FactPos> = c.site;
			if (c.access == INLINED && body != null && site != null) {
				final declared: FactPos = body;
				final ran: Span = site.span;
				final known: Null<SpliceFact> = node.splices.find(s ->
					s.body.file == declared.file && sameSpan(s.body.span, declared.span)
				);
				if (known == null)
					node.splices.push({ callee: c.target ?? '', body: declared, sites: [ran] })
				else if (!known.sites.exists(s -> sameSpan(s, ran)))
					known.sites.push(ran);
			}
		}
	}

	/** Whether `a` and `b` are the same range. */
	private static inline function sameSpan(a: Span, b: Span): Bool {
		return a.from == b.from && a.to == b.to;
	}

}

/** How a read's value is used, as a field record and a parameter's use record spell it. */
typedef UseRecord = {
	var ?u: String;
	var ?m: String;
	var ?ag: String;
	var ?aa: String;
	var ?ai: Int;
}

typedef CallRecord = {
	final ?t: String;
	final a: String;
	final ?r: String;
	final ?rp: Array<Int>;
	final rt: String;
	final ?sig: String;
	final p: Array<Int>;
	final ?s: Array<Int>;
	final ?d: Array<Int>;
	final ?o: String;
	final ?x: Bool;
}

typedef NodeRecord = {
	final id: String;
	final f: String;
	final p: Array<Int>;
	final kind: String;
	final owner: String;
	final t: String;
	final ?s: Bool;
	final ?name: String;
	final ?inc: Array<String>;
	final ?gen: Bool;
	final ?inl: String;
	final ?ov: Int;
	final ?pk: Array<Int>;
	final ?pu: Array<Array<UseRecord>>;
	final ?params: Array<{ n: String, t: String }>;
	final ?calls: Array<CallRecord>;
	final ?news: Array<{
		t: String,
		ty: String,
		p: Array<Int>,
		?gb: String
	}>;
	final ?fields: Array<{
		?o: String,
		f: String,
		a: String,
		r: String,
		t: String,
		?w: Bool,
		p: Array<Int>,
		?u: String,
		?m: String,
		?fresh: Bool,
		?h: Bool,
		?ag: String,
		?aa: String,
		?ai: Int
	}>;
	final ?elems: Array<{ r: String, rp: Array<Int>, p: Array<Int> }>;
	final ?flows: Array<{
		s: String,
		d: String,
		c: String,
		p: Array<Int>,
		?x: Bool
	}>;
	final ?hands: Array<{
		t: String,
		s: String,
		d: String,
		p: Array<Int>
	}>;
	final ?gens: Array<{ d: String, s: String, p: Array<Int> }>;
	final ?strs: Array<{ o: String, p: Array<Int>, ?x: Bool }>;
	final ?iters: Array<{ v: String, i: String, p: Array<Int> }>;
	final ?refl: Array<{
		t: String,
		?n: String,
		?m: String,
		?c: String,
		?v: Bool,
		?r: String,
		?x: Bool,
		?h: Bool,
		?o: Bool,
		p: Array<Int>
	}>;
	final ?native: Array<{
		w: String,
		n: String,
		p: Array<Int>,
		?c: String,
		?cc: Bool,
		?h: Array<String>
	}>;
	final ?vars: Array<{ n: String, t: String, p: Array<Int> }>;

	/** `[min, max, type]`, or `[file index, min, max, type]` for a foreign position. */
	final ?reads: Array<Array<Any>>;
	final ?exps: Array<{
		?t: String,
		p: Array<Int>,
		a: Array<Int>,
		?d: Array<Int>
	}>;
	final ?fns: Array<String>;
}
