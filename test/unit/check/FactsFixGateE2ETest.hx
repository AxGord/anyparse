package unit.check;

#if (sys || nodejs)
import sys.io.File;
#end
import anyparse.check.CompilerOracle;
import anyparse.check.HaxeSpawn;
import anyparse.query.Cli;
import unit.cli.CliFixture;
import utest.Assert;
import utest.Test;

/**
 * Three `--fix` gates that decline where the run cannot type something, answered by the compiler's facts over a real
 * compile: an operand of a concatenation a type in scope could overload (`fold-adjacent-string-literals`), the `extends`
 * chain of a private member's class (`unused-private`) and the receiver of a redundant `.toString()`
 * (`redundant-tostring`). Each fixture also holds the case the facts must NOT clear, and the rewritten
 * program prints what the original printed. One more pins the `reflectiveClasses` declaration end to end:
 * the declared classes a computed name may make bound the escapes a `prefer-keyvalue-loop`
 * rewrite rests on, and another the `reflectiveMethodHolders` one: the declared classes
 * whose methods a computed name may obtain bound the function values a call of a value runs. Another pins a field value stored in a
 * local and only iterated through it: the loop over the field is rewritten, and a push, a hand-off or a capture through the local keeps it.
 * Two pin a discarded map key dropped where the body provably leaves the map unchanged, under the facts and
 * from the syntax, and the last two one dropped where the map is handed only to methods that keep nothing of it.
 */
class FactsFixGateE2ETest extends Test {

	#if (sys || nodejs)
	private static final FOLD_MAIN: String = 'abstract Dir(String) from String to String {\n'
		+ '\t@:op(A + B) static function add(a:Dir, b:String):Dir\n' + '\t\treturn (a : String) + \'/\' + b;\n' + '}\n' + '\n'
		+ 'class Main {\n' + '\tstatic function name():String {\n' + '\t\treturn \'n\';\n' + '\t}\n' + '\n'
		+ '\tstatic function main() {\n' + '\t\tfinal out:Array<String> = [];\n' + '\t\tfinal xs:Array<Int> = [1, 2];\n'
		+ '\t\tfor (i in xs) {\n' + '\t\t\tout.push(\'h\' + (i - 1) + \'_p1\');\n' + '\t\t\tout.push(i + 1 + \' \' + (i * 2));\n'
		+ '\t\t}\n' + '\t\tout.push((name() : Dir) + \'x\' + \'y\');\n' + '\t\tSys.println(out.join(\',\'));\n' + '\t}\n' + '}\n';
	private static final CHAIN_MAIN: String = 'class Impl extends Base {\n' + '\tprivate function hook():Void {\n'
		+ '\t\tSys.println(\'hook\');\n' + '\t}\n' + '\n' + '\tprivate function spare():Void {\n' + '\t\tSys.println(\'s\');\n' + '\t}\n'
		+ '\n' + '\tprivate function gone():Void {\n' + '\t\tSys.println(\'g\');\n' + '\t}\n' + '}\n' + '\n'
		+ 'class Leaf extends Built {\n' + '\tprivate function kept():Void {\n' + '\t\tSys.println(\'k\');\n' + '\t}\n' + '}\n' + '\n'
		+ 'class Main {\n' + '\tstatic function main() {\n' + '\t\tnew Impl().run();\n' + '\t\tnew Leaf();\n' + '\t}\n' + '}\n';
	private static final CHAIN_BASE: String = 'abstract class Base {\n' + '\tpublic function new() {}\n' + '\n'
		+ '\tpublic function run():Void {\n' + '\t\thook();\n' + '\t}\n' + '\n' + '\tprivate abstract function hook():Void;\n' + '\n'
		+ '\tprivate abstract function spare():Void;\n' + '}\n';
	private static final CHAIN_BUILT: String = '@:autoBuild(Noop.build())\n' + 'class Built {\n' + '\tpublic function new() {}\n' + '}\n';
	private static final CHAIN_NOOP: String = 'import haxe.macro.Expr;\n' + '\n' + 'class Noop {\n'
		+ '\tpublic static macro function build():Array<Field> {\n' + '\t\treturn null;\n' + '\t}\n' + '}\n';
	private static final TOSTRING_MAIN: String = 'import haxe.io.Path;\n' + '\n' + '@:nullSafety(Strict)\n' + 'class Main {\n'
		+ '\tstatic function main() {\n' + '\t\tfinal p:Path = new Path(\'a/b.txt\');\n' + '\t\tSys.println(\'$${p.toString()}\');\n'
		+ '\t\tSys.println(\'x\' + p.toString());\n' + '\t\tSys.println(\'d $${Date.now().toString()}\'.length);\n'
		+ '\t\tfinal d:Date = Date.now();\n' + '\t\tSys.println(\'at $${d.toString()}\'.length);\n' + '\t\tfinal n:Named = new Named();\n'
		+ '\t\tSys.println(\'\\t\\t\\t\\t\\t\\t\\t\\t\\t\\t\\t\\t\\t\\t\\t$${d.toString()}$${n.label}\'.length);\n' + '\t}\n' + '}\n'
		+ '\n' + 'class Named {\n' + '\tpublic final label:String = \'l\';\n' + '\n' + '\tpublic function new() {}\n' + '}\n';
	private static final FAR_MAIN: String = 'import far.Path2;\n' + '\n' + 'abstract Dir(String) from String to String {\n'
		+ '\t@:op(A + B) static function add(a:Dir, b:String):Dir\n' + '\t\treturn (a : String) + \'/\' + b;\n' + '}\n' + '\n'
		+ 'class Holder {\n' + '\tpublic final fp:Path2 = \'r\';\n' + '\n' + '\tpublic function new() {}\n' + '}\n' + '\n'
		+ 'class Main {\n' + '\tstatic function pick<T>(v:T):T {\n' + '\t\treturn v;\n' + '\t}\n' + '\n' + '\tstatic function main() {\n'
		+ '\t\tfinal out:Array<String> = [];\n' + '\t\tfinal c:Bool = out.length == 0;\n' + '\t\tfinal fp:Path2 = \'r\';\n'
		+ '\t\tfinal h:Holder = new Holder();\n' + '\t\tfinal hs:Array<Holder> = [h];\n' + '\t\tout.push((c ? fp : fp) + \'x\' + \'y\');\n'
		+ '\t\tout.push(hs[0].fp + \'x\' + \'y\');\n' + '\t\tout.push(pick(h).fp + \'x\' + \'y\');\n'
		+ '\t\tout.push(hs.copy()[0].fp + \'x\' + \'y\');\n' + '\t\tSys.println(out.join(\',\'));\n' + '\t}\n' + '}\n';
	private static final FAR_PATH: String = 'package far;\n' + '\n' + 'abstract Path2(String) from String to String {\n'
		+ '\t@:op(A + B) static function add(a:Path2, b:String):Path2\n' + '\t\treturn (a : String) + \'/\' + b;\n' + '}\n';
	private static final NEAR_PATH: String = 'package other;\n' + '\n' + 'class Path2 {\n' + '\tpublic function new() {}\n' + '}\n';
	private static final SPLIT_MAIN: String = 'import far.Buf;\n' + 'import far.Tag;\n' + '\n' + '@:nullSafety(Strict)\n'
		+ 'class Holder {\n' + '\tpublic final tag:Tag = new Tag();\n' + '\n' + '\tpublic function new() {}\n' + '}\n' + '\n'
		+ 'class Leaf extends Built {\n' + '\tprivate function kept():Void {\n' + '\t\ttrace(\'k\');\n' + '\t}\n' + '}\n' + '\n'
		+ '@:nullSafety(Strict)\n' + 'class Main {\n' + '\tstatic function main() {\n' + '\t\tfinal hs:Array<Holder> = [new Holder()];\n'
		+ '\t\tnew Leaf();\n' + '\t\ttrace((hs[0].tag) + \'x\' + \'y\');\n' + '\t\ttrace(\'$${new Buf().toString()}|\');\n' + '\t}\n'
		+ '}\n';
	private static final SPLIT_TAG: String = 'package far;\n' + '\n' + '#if interp\n' + 'class Tag {\n' + '\tpublic function new() {}\n'
		+ '\n' + '\tpublic function toString():String {\n' + '\t\treturn \'r\';\n' + '\t}\n' + '}\n' + '#else\n'
		+ 'abstract Tag(String) {\n' + '\tpublic function new() {\n' + '\t\tthis = \'r\';\n' + '\t}\n' + '\n'
		+ '\t@:op(A + B) static function add(a:Tag, b:String):String\n' + '\t\treturn (cast a : String) + \'/\' + b;\n' + '}\n' + '#end\n';
	private static final SPLIT_NEAR_TAG: String = 'package other;\n' + '\n' + 'class Tag {\n' + '\tpublic function new() {}\n' + '}\n';
	private static final SPLIT_BUF: String = 'package far;\n' + '\n' + '#if js\n' + 'extern class Buf {\n' + '\tpublic function new();\n'
		+ '\n' + '\tpublic function toString():String;\n' + '}\n' + '#else\n' + 'class Buf {\n' + '\tpublic function new() {}\n' + '\n'
		+ '\tpublic function toString():String {\n' + '\t\treturn \'b\';\n' + '\t}\n' + '}\n' + '#end\n';
	private static final SPLIT_BUILT: String = '#if js\n' + '@:autoBuild(Noop.build())\n' + '#end\n' + 'class Built {\n'
		+ '\tpublic function new() {}\n' + '}\n';
	private static final REFLECT_MAIN: String = 'import lib.Text;\n' + '\n' + 'class Main {\n'
		+ '\tpublic static var items:Array<Int> = [1, 2];\n' + '\n' + '\tstatic function main() {\n' + '\t\tvar o:Obj = new Obj();\n'
		+ '\t\tText.keep(o);\n' + '\t\tvar n:String = \'lib.Pla\' + \'in\';\n' + '\t\tType.createInstance(Type.resolveClass(n), []);\n'
		+ '\t\tvar sum:Int = 0;\n' + '\t\tfor (i in 0...items.length) {\n' + '\t\t\tfinal v:Int = items[i];\n' + '\t\t\tsum += v;\n'
		+ '\t\t\tText.fail();\n' + '\t\t}\n' + '\t\tSys.println(sum);\n' + '\t}\n' + '}\n' + '\n' + 'class Obj {\n'
		+ '\tpublic function new() {}\n' + '\n' + '\tpublic function toString():String {\n' + '\t\tMain.items = [];\n'
		+ '\t\treturn \'o\';\n' + '\t}\n' + '}\n';
	private static final REFLECT_TEXT: String = 'package lib;\n' + '\n' + 'class Plain {\n' + '\tpublic function new() {}\n' + '}\n' + '\n'
		+ 'class Text {\n' + '\tpublic static var last:Plain = new Plain();\n' + '\n' + '\tpublic static var failing:Bool = false;\n'
		+ '\n' + '\tpublic static function keep<A>(x:A):Void {}\n' + '\n' + '\tpublic static function fail():Void {\n'
		+ '\t\tif (failing) {\n' + '\t\t\tthrow last;\n' + '\t\t}\n' + '\t}\n' + '}\n';
	private static final HOLDER_MAIN: String = 'class Main {\n' + '\tpublic static var items:Array<Int> = [1, 2];\n'
		+ '\tpublic static var keep:Null<(Rx) -> String> = null;\n' + '\n' + '\tstatic function main() {\n'
		+ '\t\tvar g:Dynamic = new Grower();\n' + '\t\tvar o:Dynamic = new Plain();\n' + '\t\tvar n:String = \'lo\' + \'ok\';\n'
		+ '\t\tkeep = Reflect.field(o, n);\n' + '\t\tfinal r:Rx = new Rx();\n' + '\t\tvar sum:Int = 0;\n'
		+ '\t\tfor (i in 0...items.length) {\n' + '\t\t\tfinal v:Int = items[i];\n' + '\t\t\tsum += v;\n' + '\t\t\tr.map(keep);\n'
		+ '\t\t}\n' + '\t\tSys.println(sum);\n' + '\t}\n' + '}\n' + '\n' + 'class Rx {\n' + '\tpublic function new() {}\n' + '\n'
		+ '\tpublic function map(f:(Rx) -> String):String {\n' + '\t\tfinal h:(Rx) -> String = f;\n' + '\t\treturn h(this);\n' + '\t}\n'
		+ '}\n' + '\n' + 'class Plain {\n' + '\tpublic function new() {}\n' + '\n' + '\tpublic function look(s:String):Void {}\n' + '}\n'
		+ '\n' + 'class Grower {\n' + '\tpublic function new() {}\n' + '\n' + '\tpublic function grow(s:String):Void {\n'
		+ '\t\tMain.items = [];\n' + '\t}\n' + '}\n';
	private static final ALIAS_MAIN: String = 'class Main {\n' + '\tpublic static var items:Array<Int> = [1, 2];\n' + '\n'
		+ '\tstatic function main() {\n' + '\t\tvar sum:Int = 0;\n' + '\t\tfor (i in 0...items.length) {\n'
		+ '\t\t\tfinal v:Int = items[i];\n' + '\t\t\tsum += v;\n' + '\t\t\tOther.go();\n' + '\t\t}\n' + '\t\tSys.println(sum);\n' + '\t}\n'
		+ '}\n';
	private static final ALIAS_OTHER: String = 'import Main.items as stuff;\n' + '\n' + 'class Other {\n'
		+ '\tstatic var done:Bool = false;\n' + '\n' + '\t#if other\n' + '\tpublic static function go():Void {}\n' + '\t#else\n'
		+ '\tpublic static function go():Void {\n' + '\t\tif (!done) {\n' + '\t\t\tdone = true;\n' + '\t\t\tstuff.push(5);\n' + '\t\t}\n'
		+ '\t}\n' + '\t#end\n' + '}\n';
	private static final REPLACE_OTHER: String = 'class Other {\n' + '\tstatic var done:Bool = false;\n' + '\n'
		+ '\tpublic static function go():Void {\n' + '\t\tif (!done) {\n' + '\t\t\tdone = true;\n' + '\t\t\tstuff = [10, 20, 30, 40];\n'
		+ '\t\t}\n' + '\t}\n' + '}\n';
	private static final HELD_MAIN: String = 'class Main {\n\tstatic function main() {\n\t\tnew Grid().run();\n\t\tnew Pushed().run();\n'
		+ '\t\tnew Handed().run();\n\t\tnew Captured().run();\n\t\tnew Returned().run();\n'
		+ '\t\tnew Shadowed().run();\n\t\tnew Region().run();\n\t}\n}\n\nclass Line {\n'
		+ '\tpublic var n:Int = 0;\n\n\tpublic function new() {}\n\n\tpublic function redraw():Void {\n'
		+ '\t\tn++;\n\t}\n}\n\nclass Grid {\n\tvar verticals:Array<Line> = [new Line(), new Line()];\n'
		+ '\tvar horizontals:Array<Line> = [new Line()];\n\n\tpublic function new() {}\n\n'
		+ '\tfunction move(c:String):Void {\n\t\tvar lines:Array<Line> = null;\n\t\tif (c == \'h\')\n'
		+ '\t\t\tlines = verticals;\n\t\telse if (c == \'v\')\n\t\t\tlines = horizontals;\n'
		+ '\t\tfor (i => line in lines) line.n += i;\n\t\tvar copy:Array<Line> = lines;\n'
		+ '\t\tfor (l in copy) l.n += copy.length;\n\t}\n\n\tpublic function run():Void {\n\t\tmove(\'h\');\n'
		+ '\t\tfor (i in 0...verticals.length) verticals[i].redraw();\n'
		+ '\t\tfor (l in verticals) Sys.println(l.n);\n\t}\n}\n\nclass Pushed {\n'
		+ '\tvar items:Array<Line> = [new Line()];\n\n\tpublic function new() {}\n\n\tfunction grow():Void {\n'
		+ '\t\tvar l:Array<Line> = null;\n\t\tl = items;\n\t\tif (l.length < 3) l.push(new Line());\n\t}\n\n'
		+ '\tpublic function run():Void {\n\t\tfor (i in 0...items.length) {\n\t\t\titems[i].redraw();\n'
		+ '\t\t\tgrow();\n\t\t}\n\t\tSys.println(items.length);\n\t}\n}\n\nclass Handed {\n'
		+ '\tstatic var kept:Array<Line> = [];\n\n\tvar items:Array<Line> = [new Line()];\n\n'
		+ '\tpublic function new() {}\n\n\tstatic function keep(a:Array<Line>):Void {\n\t\tkept = a;\n\t}\n\n'
		+ '\tfunction hand():Void {\n\t\tvar l:Array<Line> = null;\n\t\tl = items;\n\t\tkeep(l);\n\t}\n\n'
		+ '\tpublic function run():Void {\n\t\thand();\n\t\tfor (i in 0...items.length) {\n'
		+ '\t\t\titems[i].redraw();\n\t\t\tif (kept.length < 3) kept.push(new Line());\n\t\t}\n'
		+ '\t\tSys.println(items.length);\n\t}\n}\n\nclass Captured {\n'
		+ '\tvar items:Array<Line> = [new Line()];\n\tvar later:Null<() -> Void> = null;\n\n'
		+ '\tpublic function new() {}\n\n\tfunction hold():Void {\n\t\tvar l:Array<Line> = null;\n'
		+ '\t\tl = items;\n\t\tlater = () -> if (l.length < 3) l.push(new Line());\n\t}\n\n'
		+ '\tpublic function run():Void {\n\t\thold();\n\t\tfor (i in 0...items.length) {\n'
		+ '\t\t\titems[i].redraw();\n\t\t\tlater();\n\t\t}\n\t\tSys.println(items.length);\n\t}\n}\n\n'
		+ 'class Returned {\n\tvar items:Array<Line> = [new Line()];\n\n\tpublic function new() {}\n\n'
		+ '\tfunction get():Array<Line> {\n\t\tvar l:Array<Line> = null;\n\t\tl = items;\n\t\treturn l;\n\t}\n'
		+ '\n\tpublic function run():Void {\n\t\tfinal g:Array<Line> = get();\n'
		+ '\t\tfor (i in 0...items.length) {\n\t\t\titems[i].redraw();\n'
		+ '\t\t\tif (g.length < 3) g.push(new Line());\n\t\t}\n\t\tSys.println(items.length);\n\t}\n}\n\n'
		+ 'class Shadowed {\n\tstatic var kept:Array<Line> = [];\n\n\tvar items:Array<Line> = [new Line()];\n\n'
		+ '\tpublic function new() {}\n\n\tfunction hand():Void {\n\t\tvar l:Array<Line> = null;\n'
		+ '\t\tl = items;\n\t\t{\n\t\t\tvar l:Array<Line> = [new Line()];\n\t\t\tfor (x in l) x.redraw();\n'
		+ '\t\t}\n\t\tkept = l;\n\t}\n\n\tpublic function run():Void {\n\t\thand();\n'
		+ '\t\tfor (i in 0...items.length) {\n\t\t\titems[i].redraw();\n'
		+ '\t\t\tif (kept.length < 3) kept.push(new Line());\n\t\t}\n\t\tSys.println(items.length);\n\t}\n}\n\n'
		+ 'class Region {\n\tvar items:Array<Line> = [new Line()];\n\n\tpublic function new() {}\n\n'
		+ '\tpublic function run():Void {\n\t\tvar l:Array<Line> = null;\n\t\tl = items;\n'
		+ '\t\tfor (i in 0...items.length) {\n\t\t\titems[i].redraw();\n'
		+ '\t\t\tif (l.length < 3) l.push(new Line());\n\t\t}\n\t\tSys.println(items.length);\n\t}\n}\n';
	private static final MAP_MAIN: String = 'class Holder {\n\tpublic static var kept:Map<String, Int> = [];\n\n'
		+ '\tpublic static function keep(m:Map<String, Int>):Void {\n\t\tkept = m;\n\t}\n\n'
		+ '\tpublic static function poke():Void {\n\t\tkept.set(\'x\', 20);\n\t}\n}\n\nclass Registry {\n'
		+ '\tprivate final _byId:Map<Int, Array<String>> = [];\n'
		+ '\tprivate final _counts:Map<String, Int> = [\'a\' => 1, \'b\' => 2, \'c\' => 3];\n\n'
		+ '\tpublic function new() {}\n\n\tpublic function add(id:Int, s:String):Void {\n'
		+ '\t\tfinal items:Null<Array<String>> = _byId[id];\n\t\tif (items != null)\n\t\t\titems.push(s);\n'
		+ '\t\telse\n\t\t\t_byId[id] = [s];\n\t\tif (_byId.exists(-1)) _byId.remove(-1);\n\t}\n\n'
		+ '\tpublic function wipe():Void {\n\t\t_counts.clear();\n\t}\n\n\tpublic function total():Int {\n'
		+ '\t\tvar sum:Int = 0;\n\t\tfor (_ => items in _byId) sum += items.length;\n\t\treturn sum;\n\t}\n\n'
		+ '\tpublic function widest():Int {\n\t\tvar most:Int = 0;\n'
		+ '\t\tfor (id => items in _byId) if (items.length > most) most = items.length;\n\t\treturn most;\n'
		+ '\t}\n\n\tpublic function removing():String {\n\t\tfinal out:Array<Null<Int>> = [];\n'
		+ '\t\tfor (_ => n in _counts) {\n\t\t\tout.push(n);\n\t\t\t_counts.remove(\'a\');\n\t\t}\n'
		+ '\t\treturn out.join(\',\');\n\t}\n\n\tpublic function replacing():String {\n'
		+ '\t\tfinal out:Array<Null<Int>> = [];\n\t\tfor (_ => n in _counts) {\n\t\t\tout.push(n);\n'
		+ '\t\t\t_counts[\'b\'] = 20;\n\t\t}\n\t\treturn out.join(\',\');\n\t}\n\n'
		+ '\tpublic function clearing():String {\n\t\tfinal out:Array<Null<Int>> = [];\n'
		+ '\t\tfor (_ => n in _counts) {\n\t\t\tout.push(n);\n\t\t\twipe();\n\t\t}\n'
		+ '\t\treturn out.join(\',\');\n\t}\n}\n\nclass Main {\n\tstatic function main() {\n'
		+ '\t\tfinal r:Registry = new Registry();\n\t\tr.add(1, \'a\');\n\t\tr.add(2, \'b\');\n'
		+ '\t\tr.add(2, \'c\');\n\t\tSys.println(r.total());\n\t\tSys.println(r.widest());\n'
		+ '\t\tfinal fresh:Map<String, Int> = [\'p\' => 1, \'q\' => 2];\n\t\tfinal seen:Array<Int> = [];\n'
		+ '\t\tfor (_ => n in fresh) seen.push(n);\n\t\tSys.println(seen.length);\n'
		+ '\t\tfinal shared:Map<String, Int> = [\'x\' => 1, \'y\' => 2];\n\t\tHolder.keep(shared);\n'
		+ '\t\tfinal got:Array<Null<Int>> = [];\n\t\tfor (_ => n in shared) {\n\t\t\tgot.push(n);\n'
		+ '\t\t\tHolder.poke();\n\t\t}\n\t\tSys.println(got.join(\',\'));\n\t\tSys.println(r.replacing());\n'
		+ '\t\tSys.println(r.removing());\n\t\tSys.println(r.clearing());\n\t}\n}\n';
	private static final ARG_MAIN: String = 'using Lambda;\n\nclass Holder {\n\tpublic static var kept:Map<String, Int> = [];\n\n'
		+ '\tpublic static function keep(m:Map<String, Int>):Void {\n\t\tkept = m;\n\t}\n\n'
		+ '\tpublic static function poke():Void {\n\t\tkept.set(\'b\', 20);\n\t}\n}\n\nclass Registry {\n'
		+ '\tprivate final _counts:Map<String, Int> = [\'a\' => 1, \'b\' => 2, \'c\' => 3];\n'
		+ '\tprivate final _shared:Map<String, Int> = [\'a\' => 1, \'b\' => 2, \'c\' => 3];\n\n'
		+ '\tpublic function new() {}\n\n\tpublic function total():String {\n\t\tfinal out:Array<Int> = [];\n'
		+ '\t\tfor (_ => n in _counts) out.push(n);\n'
		+ '\t\treturn out.join(\',\') + \'/\' + _counts.count() + \'/\' + widest(_counts);\n\t}\n\n'
		+ '\tpublic function shared():String {\n\t\tHolder.keep(_shared);\n\t\tfinal out:Array<Null<Int>> = [];\n'
		+ '\t\tfor (_ => n in _shared) {\n\t\t\tout.push(n);\n\t\t\tHolder.poke();\n\t\t}\n'
		+ '\t\treturn out.join(\',\');\n\t}\n\n\tprivate static function widest(m:Map<String, Int>):Int {\n'
		+ '\t\tvar most:Int = 0;\n\t\tfor (n in m) if (n > most) most = n;\n\t\treturn most;\n\t}\n}\n\n'
		+ 'class Main {\n\tstatic function main() {\n\t\tfinal r:Registry = new Registry();\n'
		+ '\t\tSys.println(r.total());\n\t\tSys.println(r.shared());\n\t}\n}\n';
	private static final HXML: String = '-cp .\n-main Main\n--interp\n';
	private static inline final APQLINT: String = '{"compilerOracle":[{"hxml":"check.hxml"}],"resolutionRoots":["."]}';
	private static inline final BUFFER: Int = 1 << 20;
	#end

	/**
	 * An operand only the facts type (`(i - 1)`, `i * 2`) lets the merge through, while a check-type `(name() : Dir)` —
	 * whose value flows in as a `String` but IS a `Dir`, the type that overloads `+` — stays: the facts answer the type of
	 * the expression itself, never the source type of a conversion at its range.
	 */
	@:pin('control') @:killer('M-FOLD-FACTS-OPERAND') @:killer('M-FACTS-VALUE-TYPE-FLOWS')
	public function testAnOperandTheFactsTypeLetsTheMergeThrough(): Void {
		#if (sys || nodejs)
		final dir: Null<String> = tree('foldfacts', [{ name: 'Main.hx', source: FOLD_MAIN }], HXML);
		if (dir == null) return;
		final before: String = run(dir);
		CliFixture.captureStderr(() -> Cli.run(['lint', '--fix', '--rule', 'fold-adjacent-string-literals', dir]));
		final after: String = File.getContent('$dir/Main.hx');
		Assert.isTrue(after.indexOf('out.push(\'h$${(i - 1)}_p1\');') >= 0, after);
		Assert.isTrue(after.indexOf('out.push(\'$${i + 1} $${(i * 2)}\');') >= 0, after);
		Assert.isTrue(after.indexOf('out.push((name() : Dir) + \'x\' + \'y\');') >= 0, after);
		Assert.equals(before, run(dir), 'the program prints what it printed');
		CliFixture.removeDir(dir);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/**
	 * An operand the facts type as `far.Path2` — an abstract overloading `+` that the resolution scope does not declare —
	 * stays, though the scope's own `Path2` is a plain class: the overload table judges a simple name, so the facts name
	 * only a type no operator can be declared on.
	 */
	@:pin('control') @:killer('M-FOLD-FACTS-PLAIN-KINDS')
	public function testAnAbstractTheFactsTypeIsNeverJudgedByAnotherDeclarationOfItsName(): Void {
		#if (sys || nodejs)
		final dir: Null<String> = tree('foldfar', [
			{ name: 'src/Main.hx', source: FAR_MAIN },
			{ name: 'src/other/Path2.hx', source: NEAR_PATH },
			{ name: 'lib/far/Path2.hx', source: FAR_PATH }
		], '-cp src\n-cp lib\n-main Main\n--interp\n', '{"compilerOracle":[{"hxml":"check.hxml"}],"resolutionRoots":["src"]}');
		if (dir == null) return;
		final before: String = run(dir);
		CliFixture.captureStderr(() -> Cli.run(['lint', '--fix', '--rule', 'fold-adjacent-string-literals', '$dir/src']));
		Assert.equals(FAR_MAIN, File.getContent('$dir/src/Main.hx'));
		Assert.equals(before, run(dir), 'the program prints what it printed');
		CliFixture.removeDir(dir);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/**
	 * A private member of a class whose supertypes live outside the resolution scope goes once the facts show no supertype
	 * declares it; one an abstract supertype declares stays, and so does one of a class under a supertype's `@:autoBuild`.
	 */
	@:pin('control') @:killer('M-UNUSED-PRIVATE-CHAIN-FACTS') @:killer('M-UNUSED-PRIVATE-CHAIN-DECLARED')
	@:killer('M-UNUSED-PRIVATE-CHAIN-AUTOBUILD')
	public function testAPrivateMemberNoSupertypeDeclaresIsDeleted(): Void {
		#if (sys || nodejs)
		final dir: Null<String> = tree('chainfacts', [
			{ name: 'src/Main.hx', source: CHAIN_MAIN },
			{ name: 'lib/Base.hx', source: CHAIN_BASE },
			{ name: 'lib/Built.hx', source: CHAIN_BUILT },
			{ name: 'lib/Noop.hx', source: CHAIN_NOOP }
		], '-cp src\n-cp lib\n-main Main\n--interp\n', '{"compilerOracle":[{"hxml":"check.hxml"}],"resolutionRoots":["src"]}');
		if (dir == null) return;
		final before: String = run(dir);
		CliFixture.captureStderr(() -> Cli.run(['lint', '--fix', '--rule', 'unused-private', '$dir/src']));
		final after: String = File.getContent('$dir/src/Main.hx');
		Assert.isTrue(after.indexOf('function gone') < 0, after);
		for (kept in ['function hook', 'function spare', 'function kept']) Assert.isTrue(after.indexOf(kept) >= 0, '$kept\n$after');
		Assert.equals(before, run(dir), 'the program prints what it printed');
		CliFixture.removeDir(dir);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/**
	 * A receiver of a class the resolution scope does not declare (`haxe.io.Path`) loses its `.toString()` once the facts
	 * show every configuration compiled it as a non-extern class; an extern one (`Date` on `--interp`) keeps it — also
	 * where, after fifteen escapes, the compiler places the read of `n` exactly at `d`'s range. `'at ${d.toString()}'` is
	 * the site only the extern gate decides: `Date.now()` is not provably non-null while the unindexed `haxe.io.Path`
	 * import may declare a `Date` of its own, and the escaped read is declined before its type is asked.
	 */
	@:pin('control') @:killer('M-TOSTRING-FACTS-CLASS') @:killer('M-TOSTRING-FACTS-EXTERN') @:killer('M-FACTS-ESCAPE-SHIFT')
	public function testAReceiverTheFactsTypeAsANonExternClassLosesItsToString(): Void {
		#if (sys || nodejs)
		final dir: Null<String> = tree('tostringfacts', [{ name: 'Main.hx', source: TOSTRING_MAIN }], HXML);
		if (dir == null) return;
		final before: String = run(dir);
		CliFixture.captureStderr(() -> Cli.run(['lint', '--fix', '--rule', 'redundant-tostring', dir]));
		final after: String = File.getContent('$dir/Main.hx');
		Assert.isTrue(after.indexOf('Sys.println(\'$$p\');') >= 0, after);
		Assert.isTrue(after.indexOf('Sys.println(\'x\' + p);') >= 0, after);
		Assert.isTrue(after.indexOf('Date.now().toString()') >= 0, after);
		Assert.isTrue(after.indexOf('at $${d.toString()}') >= 0, after);
		Assert.isTrue(after.indexOf('\\t$${d.toString()}') >= 0, after);
		Assert.equals(before, run(dir), 'the program prints what it printed');
		CliFixture.removeDir(dir);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/**
	 * Two configurations that record one type differently leave every fix off: `far.Tag` is a class on `--interp` and an
	 * abstract overloading `+` on js, `far.Buf` a class on `--interp` and an extern one on js, and `Built` is under
	 * `@:autoBuild` on js only. The `--interp` configuration is listed first, so its record is the one the table keeps, and
	 * only the agreement flag and the metadata union stand between it and a fix that changes the js build. The `Tag`
	 * operand is parenthesized: unwrapped, the compiler's inserted `Std.string` puts its receiver at the operand's range.
	 */
	@:pin('control') @:killer('M-FACTS-ALIKE-FOLD') @:killer('M-FACTS-ALIKE-TOSTRING') @:killer('M-FACTS-META-UNION')
	public function testWhatTheConfigurationsRecordDifferentlyKeepsEveryFixOff(): Void {
		#if (sys || nodejs)
		final dir: Null<String> = tree('splitfacts', [
			{ name: 'src/Main.hx', source: SPLIT_MAIN },
			{ name: 'src/other/Tag.hx', source: SPLIT_NEAR_TAG },
			{ name: 'lib/far/Tag.hx', source: SPLIT_TAG },
			{ name: 'lib/far/Buf.hx', source: SPLIT_BUF },
			{ name: 'lib/Built.hx', source: SPLIT_BUILT },
			{ name: 'lib/Noop.hx', source: CHAIN_NOOP },
			{ name: 'js.hxml', source: '-cp src\n-cp lib\n-main Main\n-js out.js\n' }
		], '-cp src\n-cp lib\n-main Main\n--interp\n', '{"compilerOracle":[{"hxml":"check.hxml"},{"hxml":"js.hxml"}],"resolutionRoots":["src"]}');
		if (dir == null) return;
		final before: String = run(dir);
		CliFixture.captureStderr(() -> Cli.run([
			'lint',
			'--fix',
			'--rule',
			'fold-adjacent-string-literals',
			'--rule',
			'redundant-tostring',
			'--rule',
			'unused-private',
			'$dir/src'
		]));
		Assert.equals(SPLIT_MAIN, File.getContent('$dir/src/Main.hx'));
		Assert.equals(before, run(dir), 'the program prints what it printed');
		CliFixture.removeDir(dir);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/**
	 * A class value made from a name computed at run time may be of any class, so a run knows nothing of what escapes and
	 * the loop whose body may convert a value of no known type stays; declared `reflectiveClasses` bound it — `lib.Plain`,
	 * which holds no `Obj` — and the loop is rewritten, while a declaration naming `Obj` keeps it. A glob matching no
	 * class the builds typed is reported.
	 */
	@:pin('control') @:killer('M-REFLECTIVE-BUILDS') @:killer('M-REFLECTIVE-REACH') @:killer('M-REFLECTIVE-WARN')
	@:killer('M-ESCAPES-FACTS-UNMATCHED')
	public function testAComputedClassNameTheProjectBoundsLetsTheLoopRewrite(): Void {
		#if (sys || nodejs)
		final complete: String = '{"compilerOracle":[{"hxml":"check.hxml"}],"resolutionRoots":["."],"reachConfigurationsComplete":true';
		final files: Array<{ name: String, source: String }> = [
			{ name: 'Main.hx', source: REFLECT_MAIN },
			{ name: 'lib/Text.hx', source: REFLECT_TEXT }
		];
		for (declared in ['', ',"reflectiveClasses":["lib.*","Obj"]']) {
			final dir: Null<String> = tree('reflectkept', files, HXML, complete + declared + '}');
			if (dir == null) return;
			CliFixture.captureStderr(() -> Cli.run(['lint', '--fix', '--rule', 'prefer-keyvalue-loop', '$dir/Main.hx']));
			Assert.equals(REFLECT_MAIN, File.getContent('$dir/Main.hx'), declared);
			CliFixture.removeDir(dir);
		}
		final dir: Null<String> = tree('reflectbound', files, HXML, complete + ',"reflectiveClasses":["lib.*","nope.**"]}');
		if (dir == null) return;
		final before: String = run(dir);
		final err: String = CliFixture.captureStderr(() -> Cli.run(['lint', '--fix', '--rule', 'prefer-keyvalue-loop', '$dir/Main.hx']));
		final after: String = File.getContent('$dir/Main.hx');
		Assert.isTrue(after.indexOf('for (i => v in items) {') >= 0, after);
		Assert.isTrue(err.indexOf('reflectiveClasses "nope.**" matches no class the builds typed') >= 0, err);
		Assert.isTrue(err.indexOf('"lib.*" matches no class') < 0, err);
		Assert.equals(before, run(dir), 'the program prints what it printed');
		CliFixture.removeDir(dir);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/**
	 * A method read by a name computed at run time may be any method of any escaped object — `Grower.grow`, which empties
	 * the list, among them — so the loop whose body calls a function value stays; declared `reflectiveMethodHolders`
	 * bound it — `Plain`, whose `look` the name makes — and the loop is rewritten, while a declaration naming `Grower` keeps
	 * it. A glob matching no class the builds typed is reported.
	 */
	@:pin('control') @:killer('M-HOLDERS-BUILDS') @:killer('M-HOLDERS-REACH') @:killer('M-HOLDERS-WARN') @:killer('M-HOLDERS-READ')
	public function testAComputedMemberNameTheProjectBoundsLetsTheLoopRewrite(): Void {
		#if (sys || nodejs)
		final complete: String = '{"compilerOracle":[{"hxml":"check.hxml"}],"resolutionRoots":["."],"reachConfigurationsComplete":true';
		final files: Array<{ name: String, source: String }> = [{ name: 'Main.hx', source: HOLDER_MAIN }];
		for (declared in ['', ',"reflectiveMethodHolders":["Plain","Grower"]']) {
			final dir: Null<String> = tree('holderkept', files, HXML, complete + declared + '}');
			if (dir == null) return;
			CliFixture.captureStderr(() -> Cli.run(['lint', '--fix', '--rule', 'prefer-keyvalue-loop', '$dir/Main.hx']));
			Assert.equals(HOLDER_MAIN, File.getContent('$dir/Main.hx'), declared);
			CliFixture.removeDir(dir);
		}
		final dir: Null<String> = tree('holderbound', files, HXML, complete + ',"reflectiveMethodHolders":["Plain","nope.**"]}');
		if (dir == null) return;
		final before: String = run(dir);
		final err: String = CliFixture.captureStderr(() -> Cli.run(['lint', '--fix', '--rule', 'prefer-keyvalue-loop', '$dir/Main.hx']));
		final after: String = File.getContent('$dir/Main.hx');
		Assert.isTrue(after.indexOf('for (i => v in items) {') >= 0, after);
		Assert.isTrue(err.indexOf('reflectiveMethodHolders "nope.**" matches no class the builds typed') >= 0, err);
		Assert.isTrue(err.indexOf('"Plain" matches no class') < 0, err);
		Assert.equals(before, run(dir), 'the program prints what it printed');
		CliFixture.removeDir(dir);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/**
	 * `stuff`, pushed to once by the `go` the build compiles, is `Main.items` imported under another name: under the truth
	 * the loop, whose element iterator would follow the push, stays. The reading a run asks first sees the alias itself now
	 * (`testAStaticImportedUnderAnotherNameKeepsTheLoopWithoutTheTruth`), so this pins no arm: that a proof is asked again
	 * under the truth is `MemberReachFactsTest.testAProofTheTruthContradictsIsAskedAgainUnderTheTruth`'s.
	 */
	public function testAStaticImportedUnderAnotherNameKeepsTheLoopUnderTheTruth(): Void {
		#if (sys || nodejs)
		final complete: String = '{"compilerOracle":[{"hxml":"check.hxml"}],"resolutionRoots":["."],"reachConfigurationsComplete":true}';
		final dir: Null<String> = tree('aliasproof', [
			{ name: 'Main.hx', source: ALIAS_MAIN },
			{ name: 'Other.hx', source: ALIAS_OTHER }
		], HXML, complete);
		if (dir == null) return;
		final before: String = run(dir);
		CliFixture.captureStderr(() -> Cli.run(['lint', '--fix', '--rule', 'prefer-keyvalue-loop', '$dir/Main.hx']));
		Assert.equals(ALIAS_MAIN, File.getContent('$dir/Main.hx'));
		Assert.equals(before, run(dir), 'the program prints what it printed');
		CliFixture.removeDir(dir);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/**
	 * With no list of builds to answer it, the syntax reads `stuff` — `Main.items` imported under another name, in the file
	 * spelling it or in an `import.hx` beside it — as the member: the `go` the loop calls replaces it, so the loop, whose
	 * element iterator would keep walking the old one, stays (rewritten, the program printed 3 instead of 21).
	 */
	@:pin('control') @:killer('M-REACH-IMPORT-ALIAS') @:killer('M-REACH-IMPORT-ALIAS-WORDS')
	public function testAStaticImportedUnderAnotherNameKeepsTheLoopWithoutTheTruth(): Void {
		#if (sys || nodejs)
		final apqlint: String = '{"compilerOracle":[{"hxml":"check.hxml"}],"resolutionRoots":["."]}';
		final own: Array<{ name: String, source: String }> = [
			{
				name: 'Other.hx',
				source: 'import Main.items as stuff;\n\n' + REPLACE_OTHER
			}
		];
		final ambient: Array<{ name: String, source: String }> = [
			{ name: 'Other.hx', source: REPLACE_OTHER },
			{ name: 'import.hx', source: 'import Main.items as stuff;\n' }
		];
		for (other in [own, ambient]) {
			final dir: Null<String> = tree('aliasreplace', [{ name: 'Main.hx', source: ALIAS_MAIN }].concat(other), HXML, apqlint);
			if (dir == null) return;
			final before: String = run(dir);
			CliFixture.captureStderr(() -> Cli.run(['lint', '--fix', '--rule', 'prefer-keyvalue-loop', '$dir/Main.hx']));
			Assert.equals(ALIAS_MAIN, File.getContent('$dir/Main.hx'), other[other.length - 1].name);
			Assert.equals(before, run(dir), 'the program prints what it printed');
			CliFixture.removeDir(dir);
		}
		#else
		Assert.pass('non-sys target');
		#end
	}

	/**
	 * `Grid.move` stores `verticals` — or `horizontals` — in a local, in either branch, and in another local after it, and
	 * only iterates them: under the truth the loop over `verticals` is rewritten. A push through such a local, handing it
	 * on, capturing it, returning it, or handing on the outer local past a block that declares one of its name, keeps the
	 * loop, and so does a push through the local inside the loop, whose store lies before it: each would make the rewritten
	 * loop see an element it did not see.
	 */
	@:pin('control') @:killer('M-FACTS-ASSIGN-HELD') @:killer('M-TOUCH-TYPED-HELD-REGION')
	public function testAValueStoredInALocalOnlyIteratedLetsTheLoopRewrite(): Void {
		#if (sys || nodejs)
		final complete: String = '{"compilerOracle":[{"hxml":"check.hxml"}],"resolutionRoots":["."],"reachConfigurationsComplete":true}';
		final dir: Null<String> = tree('heldlocal', [{ name: 'Main.hx', source: HELD_MAIN }], HXML, complete);
		if (dir == null) return;
		final before: String = run(dir);
		CliFixture.captureStderr(() -> Cli.run(['lint', '--fix', '--rule', 'prefer-value-loop', '$dir/Main.hx']));
		final expected: String = StringTools.replace(
			HELD_MAIN, 'for (i in 0...verticals.length) verticals[i].redraw();', 'for (vertical in verticals) vertical.redraw();'
		);
		Assert.notEquals(HELD_MAIN, expected);
		Assert.equals(expected, File.getContent('$dir/Main.hx'));
		Assert.equals(before, run(dir), 'the program prints what it printed');
		CliFixture.removeDir(dir);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/**
	 * A discarded key over a standard map goes where `MemberReach` proves nothing the loop body runs changes the map —
	 * the field `_byId`, which only `add` writes, for both `redundant-map-iter-key` and `unused-loop-binder`, and a local
	 * map built in place — under the compiler facts as the truth. A body that removes an entry, replaces a value, calls a
	 * method that clears the map, or changes a local map through the static another function stored it in keeps its key:
	 * each would read through the key what the value iterator does not (rewritten, the program prints `3,2,1` / `3,20` /
	 * `2,1` where it printed `3,20,1` / `3,null` / `2,20`).
	 */
	@:pin('control') @:killer('M-TOUCH-MAP-METHODS-UNKNOWN') @:killer('M-REACH-LOCAL-MAP-ALIAS-PROVEN')
	public function testAMapTheLoopLeavesUnchangedLosesItsKeyUnderTheTruth(): Void {
		#if (sys || nodejs)
		mapKeysDropped('{"compilerOracle":[{"hxml":"check.hxml"}],"resolutionRoots":["."],"reachConfigurationsComplete":true}');
		#else
		Assert.pass('non-sys target');
		#end
	}

	/** The same proofs and refusals read from the syntax alone, with no compiler facts. */
	@:pin('control') @:killer('M-TOUCH-MAP-METHODS-UNKNOWN')
	public function testAMapTheLoopLeavesUnchangedLosesItsKeyFromItsSyntax(): Void {
		#if (sys || nodejs)
		mapKeysDropped('{"resolutionRoots":["."]}');
		#else
		Assert.pass('non-sys target');
		#end
	}

	/**
	 * A map handed to `Lambda.count` (by `using`, the compiler casting it to an `Iterable`) and to a method that only iterates
	 * it is kept by neither: under the compiler facts the loop over it drops its key, and the program prints what it printed. A
	 * map handed to `Holder.keep`, which stores it where `Holder.poke` replaces a value inside the loop, keeps its key — the
	 * value iterator would print `3,2,1` where it printed `3,20,1`.
	 */
	@:pin('control') @:killer('M-FACTS-ARGUMENT-USE') @:killer('M-FACTS-ARGUMENT-CAST') @:killer('M-FACTS-ABSTRACT-WRAPPED-CAST')
	@:killer('M-FACTS-IDENTITY-CAST-VALUE') @:killer('M-TOUCH-ARGUMENT-USES') @:killer('M-GRAPH-MAP-USER-CODE')
	public function testAMapHandedToMethodsThatKeepNothingLosesItsKeyUnderTheTruth(): Void {
		#if (sys || nodejs)
		argumentKeysDropped('{"compilerOracle":[{"hxml":"check.hxml"}],"resolutionRoots":["."],"reachConfigurationsComplete":true}', true);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/** The same fixture with no list of builds declared complete: the syntax reads every argument as an escape, and nothing changes. */
	public function testAMapHandedToAMethodKeepsItsKeyWithoutTheTruth(): Void {
		#if (sys || nodejs)
		argumentKeysDropped('{"compilerOracle":[{"hxml":"check.hxml"}],"resolutionRoots":["."]}', false);
		#else
		Assert.pass('non-sys target');
		#end
	}

	#if (sys || nodejs)
	/** The map fixture fixed by both key-dropping rules under `apqlint`: exactly the three provable loops change, and the output does not. */
	private static function mapKeysDropped(apqlint: String): Void {
		final dir: Null<String> = tree('mapkeys', [{ name: 'Main.hx', source: MAP_MAIN }], HXML, apqlint);
		if (dir == null) return;
		final before: String = run(dir);
		CliFixture.captureStderr(() -> Cli.run([
			'lint',
			'--fix',
			'--rule',
			'redundant-map-iter-key',
			'--rule',
			'unused-loop-binder',
			'$dir/Main.hx'
		]));
		var expected: String = MAP_MAIN;
		for (pair in [
			['for (_ => items in _byId) sum', 'for (items in _byId) sum'],
			['for (id => items in _byId) if', 'for (items in _byId) if'],
			['for (_ => n in fresh)', 'for (n in fresh)']
		]) {
			Assert.isTrue(expected.indexOf(pair[0]) >= 0, pair[0]);
			expected = StringTools.replace(expected, pair[0], pair[1]);
		}
		Assert.equals(expected, File.getContent('$dir/Main.hx'));
		Assert.equals(before, run(dir), 'the program prints what it printed');
		CliFixture.removeDir(dir);
	}
	/** The argument fixture fixed by `redundant-map-iter-key` under `apqlint`: the `_counts` loop changes when `dropped`, and the output does not. */
	private static function argumentKeysDropped(apqlint: String, dropped: Bool): Void {
		final dir: Null<String> = tree('argkeys', [{ name: 'Main.hx', source: ARG_MAIN }], HXML, apqlint);
		if (dir == null) return;
		final before: String = run(dir);
		CliFixture.captureStderr(() -> Cli.run(['lint', '--fix', '--rule', 'redundant-map-iter-key', '$dir/Main.hx']));
		final from: String = 'for (_ => n in _counts) out';
		Assert.isTrue(ARG_MAIN.indexOf(from) >= 0, from);
		final expected: String = dropped ? StringTools.replace(ARG_MAIN, from, 'for (n in _counts) out') : ARG_MAIN;
		Assert.equals(expected, File.getContent('$dir/Main.hx'));
		Assert.equals(before, run(dir), 'the program prints what it printed');
		CliFixture.removeDir(dir);
	}
	#end

	#if (sys || nodejs)
	/** The fixture tree, or null — the test passed as skipped — when no `haxe` typechecks it. */
	private static function tree(
		name: String, files: Array<{ name: String, source: String }>, hxml: String, apqlint: String = APQLINT
	): Null<String> {
		final dir: String = CliFixture.writeTree(
			name, files.concat([{ name: 'check.hxml', source: hxml }, { name: 'apqlint.json', source: apqlint }])
		);
		if (CompilerOracle.typecheck('check.hxml', dir).match(Confirmed)) return dir;
		CliFixture.removeDir(dir);
		Assert.pass('haxe unavailable — skipped');
		return null;
	}

	private static function run(dir: String): String {
		return HaxeSpawn.run(['check.hxml'], dir, BUFFER).out;
	}
	#end

}
