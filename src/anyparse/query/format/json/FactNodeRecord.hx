package anyparse.query.format.json;

import anyparse.grammar.json.JValue;

/** A facts file's node record (`{"k":"node",…}`, written by `TypedFactsMacro`). */
@:peg @:schema(anyparse.grammar.json.JsonFormat) @:ws
typedef FactNodeRecord = {

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
	final ?pu: Array<Array<FactUseRecord>>;
	final ?params: Array<FactParamRecord>;
	final ?calls: Array<FactCallRecord>;
	final ?news: Array<FactNewRecord>;
	final ?fields: Array<FactFieldRecord>;
	final ?elems: Array<FactElemRecord>;
	final ?flows: Array<FactFlowRecord>;
	final ?hands: Array<FactHandRecord>;
	final ?gens: Array<FactGenRecord>;
	final ?strs: Array<FactStrRecord>;
	final ?iters: Array<FactIterRecord>;
	final ?refl: Array<FactReflRecord>;
	final ?native: Array<FactNativeRecord>;
	final ?vars: Array<FactVarRecord>;

	/** `[min, max, type, name]`, or `[file index, min, max, type, name]` for a foreign position. */
	final ?reads: Array<Array<JValue>>;
	final ?exps: Array<FactExpRecord>;
	final ?fns: Array<String>;

}
