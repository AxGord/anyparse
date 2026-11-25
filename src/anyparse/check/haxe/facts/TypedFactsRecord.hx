package anyparse.check.haxe.facts;

import anyparse.check.haxe.oracle.ReachConfigurationRecord;
import anyparse.proc.ProcessRun;

/**
 * The file `TypedFactsCache` keeps beside one configuration's facts dump: the key of the input the compile read, the md5 of
 * the dump it wrote, and what the same compile answered besides — its `-v` typecheck and its build.
 */
@:peg
@:schema(anyparse.grammar.json.JsonFormat)
@:ws
typedef TypedFactsRecord = {
	var format: String;
	var key: String;
	var facts: String;
	var verbose: ProcessRun;
	var configuration: ReachConfigurationRecord;
}
