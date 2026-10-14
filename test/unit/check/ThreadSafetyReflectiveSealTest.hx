package unit.check;

import utest.Assert;
import utest.Test;

/**
 * Reflective writes against the lock names (`FieldWrites.reflectivelyWritten`, review N2 / F3): a write of a computed name
 * on a value the run places on no class may store any lock in any lock member, so it unseals every one — the sound
 * default. What keeps a lock member sealed is a POSITIVE exclusion that bounds what the value is (`FieldWrites.placeOf`):
 * a `final` local bound to a fresh structure or object, a `case` capture typed by its enum constructor, a type parameter
 * bounded by its constraint or by every instantiation of its class.
 */
class ThreadSafetyReflectiveSealTest extends Test {

	#if (sys || nodejs)
	private static inline final RULE: String = '"thread-safety":{"sinks":["Mutex.acquire","Sys.sleep"],"spawns":["Runner.create"],'
		+ '"lockPairs":["Mutex.acquire/release"]';

	/** The rule over a closed project that declares no class made from a computed name (`reflectiveClasses`). */
	private static inline final CLOSED: String = '{"reflectiveClasses":["nothing.*"],"rules":{$RULE,"closedWorld":true}}}';

	/** `CLOSED`, declaring too that a read of a computed name obtains no method (`reflectiveMethodHolders`). */
	private static inline final SEALED: String = '{"reflectiveClasses":["nothing.*"],"reflectiveMethodHolders":["nothing.*"],'
		+ '"rules":{$RULE,"closedWorld":true}}}';
	#end

	/**
	 * A computed name on a value the typer cannot place — a library container's element, an array element, an
	 * un-annotated local of a library call, `Dynamic` — unseals `_l`, so the main thread's take of it stays reported, and
	 * the run names the writer; a `case` capture is typed by its enum constructor's parameter (`D`, which declares `_l`),
	 * a capture of a `Map` parameter is an element write, not a reflective one, and a constructor
	 * name two enums declare types the capture by the enum its subject is declared of.
	 */
	@:pin('control') @:killer('M-TS-SEAL-REFLECT-UNPLACED') @:killer('M-TS-SEAL-UNPLACED-NOTICE') @:killer('M-TS-BINDER-TYPE')
	public function testAValueTheRunCannotPlaceUnsealsEveryLock(): Void {
		#if (sys || nodejs)
		Assert.equals(1, quickTakes('Reflect.setField(owners.first(), k, _m);'), 'a library container element');
		Assert.equals(1, quickTakes('Reflect.setField(arr[0], k, _m);'), 'an array element');
		Assert.equals(1, quickTakes('final o = owners.first(); Reflect.setField(o, k, _m);'), 'an un-annotated local');
		Assert.equals(1, quickTakes('final o:Dynamic = owners.first(); Reflect.setField(o, k, _m);'), 'a Dynamic local');
		Assert.equals(1, quickTakes('final o:D = owners.first(); Reflect.setField(o, k, _m);'), 'a local of its class');
		Assert.equals(1, quickTakes('switch box { case Holder(v): Reflect.setField(v, k, _m); case _: }'), 'a capture of class D');
		Assert.equals(1, quickTakes('switch box { case Pack(v): Reflect.setField(v, k, _m); case _: }'), 'an ambiguous capture');
		Assert.equals(0, quickTakes('switch box { case Bag(m): m[k] = new Mutex(); case _: }'), 'a capture of a Map');
		Assert.equals(
			1, found('Reflect.setField(arr[0], k, _m);').filter(f -> f.indexOf('so no lock is named by its member: D.alias') != -1).length,
			'the run names the writer'
		);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/**
	 * A `final` local bound to a fresh structure writes into that structure, whatever it escapes to, and one bound to
	 * `new Other()` into an `Other`: neither class declares `_l`, which stays sealed, and the run says which exclusion
	 * held. A fresh `D` declares it; a `var` may be bound again.
	 */
	@:pin('control') @:killer('M-TS-PLACE-FRESH-STRUCT') @:killer('M-TS-PLACE-FRESH-NEW') @:killer('M-TS-PLACE-FRESH-MUTABLE')
	public function testAFreshObjectReceiverKeepsTheLockNames(): Void {
		#if (sys || nodejs)
		Assert.equals(0, quickTakes('final y:Dynamic = {}; Reflect.setField(y, k, _m);'), 'a fresh structure');
		Assert.equals(0, quickTakes('final y:Dynamic = new Other(); Reflect.setField(y, k, _m);'), 'a fresh Other');
		Assert.equals(1, quickTakes('final y:Dynamic = new D(); Reflect.setField(y, k, _m);'), 'a fresh D');
		Assert.equals(1, quickTakes('var y:Dynamic = {}; Reflect.setField(y, k, _m);'), 'a var');
		Assert.equals(
			1,
			found('final y:Dynamic = {}; Reflect.setField(y, k, _m);').filter(f -> f.indexOf('D.alias (a fresh structure)') != -1).length,
			'the run says which exclusion held'
		);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/**
	 * `Node<T>`'s `targetObject:T` written by a computed name: every subclass binds `T` — to `Void`, which holds no value, to
	 * a parameter its constraint bounds by `Other` (a `final` class's `extends` included) — and `Node` itself is never made,
	 * so `_l` stays sealed (a static call on `Node` makes none). Each unbounded instantiation unseals it: a `new Node`, the
	 * class read as a value, a link through an alias that writes no argument, a free subclass that is made, a run that
	 * does not cover a closed project, a project declaring no `reflectiveClasses` or declaring one that names `Node`. A
	 * method's own type parameter is bounded by its constraint alone.
	 */
	@:pin('control') @:killer('M-TS-PLACE-INSTANTIATIONS') @:killer('M-TS-PLACE-COMPLETE') @:killer('M-TS-PLACE-RAW-LINK')
	@:killer('M-TS-PLACE-FREE-SUB') @:killer('M-TS-PLACE-NEVER-MADE') @:killer('M-TS-PLACE-UNDECLARED')
	@:killer('M-TS-PLACE-GLOB-MATCH') @:killer('M-TS-PLACE-MAKES-NEW') @:killer('M-TS-PLACE-MAKES-VALUE')
	@:killer('M-TS-PLACE-MAKES-RECEIVER') @:killer('M-TS-PLACE-VOID') @:killer('M-TS-PLACE-FORWARDED-BOUND')
	@:killer('M-TS-PLACE-PARAM-CONSTRAINT') @:killer('M-TS-PLACE-PARAM-OWNER') @:killer('M-TS-FINAL-SUPERS-WRITTEN')
	@:killer('M-TS-REACH-ALIAS-SUBTYPES')
	public function testATypeParameterReceiverIsBoundedByItsInstantiations(): Void {
		#if (sys || nodejs)
		final use: String = 'new V().toTarget("_l", d._m);';
		Assert.equals(0, nodeTakes(CLOSED, '', use), 'bounded by its instantiations');
		Assert.equals(
			1,
			nodeFindings(CLOSED, '', use)
				.filter(f -> f.indexOf('Node.toTarget (type parameter T of Node, bounded by its instantiations)') != -1)
				.length,
			'the run says which exclusion held'
		);
		Assert.equals(
			1, nodeTakes(CLOSED, '', 'final n:Node<D> = new Node<D>(); n.targetObject = d; n.toTarget("_l", d._m);'), 'a new Node'
		);
		Assert.equals(
			1, nodeTakes(CLOSED, '', 'final n:Node<D> = Type.createInstance(Node, []); n.toTarget("_l", d._m);'), 'a class value'
		);
		Assert.equals(1, nodeTakes(CLOSED, 'typedef N = Node<D>; class R extends N {}', use), 'an alias link');
		Assert.equals(1, nodeTakes(CLOSED, 'class G<Y> extends Node<Y> {}', 'new G<D>().toTarget("_l", d._m);'), 'a free subclass made');
		Assert.equals(1, nodeTakes('{"reflectiveClasses":["nothing.*"],"rules":{$RULE}}}', '', use), 'no closed project');
		Assert.equals(1, nodeTakes('{"rules":{$RULE,"closedWorld":true}}}', '', use), 'no reflectiveClasses');
		Assert.equals(1, nodeTakes('{"reflectiveClasses":["Node"],"rules":{$RULE,"closedWorld":true}}}', '', use), 'Node declared');
		Assert.equals(
			1,
			nodeTakes(
				CLOSED, '', 'new V().put(d, "_l", d._m);', 'public function put<T>(o:T, k:String, m:Mutex):Void Reflect.setField(o, k, m);'
			),
			"a method's own type parameter"
		);
		Assert.equals(0, nodeTakes(CLOSED, '', 'Node.poke(new Other(), "_l", d._m);'), "a method's bounded type parameter");
		#else
		Assert.pass('non-sys target');
		#end
	}

	/**
	 * A lock member a reflective write unseals names no lock, so its holds are keyed by the pair's take: each finding of
	 * such a hold or take says which member lost its name and which writers unsealed it, and the run says how many holds
	 * lost their lock name and which precondition of the instantiation bound the run fails.
	 */
	@:pin('control') @:killer('M-TS-UNSEALED-NOTE') @:killer('M-TS-UNSEALED-HOLDS') @:killer('M-TS-UNSEALED-PRECONDITIONS')
	@:killer('M-TS-UNSEALED-TAKE') @:killer('M-TS-UNSEALED-THROW')
	public function testALockAReflectiveWriteUnsealsSaysWhoUnsealedIt(): Void {
		#if (sys || nodejs)
		final note: String = 'its lock member _l names no lock: a reflective write may store any lock in it (D.alias)';
		final all: Array<String> = unsealedFindings('Reflect.setField(arr[0], k, m);');
		Assert.equals(1, all.filter(f -> f.indexOf('D.quick -> Mutex.acquire') != -1 && f.indexOf(note) != -1).length, 'the take');
		Assert.equals(1, all.filter(f -> f.indexOf('"D.work" holds') != -1 && f.indexOf(note) != -1).length, 'the hold');
		Assert.equals(1, all.filter(f -> f.indexOf('"D.risky" leaves') != -1 && f.indexOf(note) != -1).length, 'the hold left on a throw');
		Assert.equals(
			1,
			all.filter(
				f ->
					f.indexOf('3 lock hold(s) lost the name of their lock member') != -1
					&& f.indexOf('here: no closedWorld over the whole project, no reflectiveClasses') != -1
			)
				.length,
			'the run counts them and says what is missing'
		);
		Assert.equals(
			0, unsealedFindings('final y:Dynamic = {}; Reflect.setField(y, k, m);').filter(f -> f.indexOf('names no lock') != -1).length,
			'sealed'
		);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/**
	 * A `case` capture is typed by its enum constructor only when the switch subject is declared of that enum: a capture
	 * of a library `Option` or `Either` whose constructor's name a project enum declares too stays untyped, and the run
	 * says which capture an enum constructor typed.
	 */
	@:pin('control') @:killer('M-TS-BINDER-SUBJECT') @:killer('M-TS-BINDER-PLACED-BY') @:killer('M-TS-BINDER-TOP')
	@:killer('M-TS-BINDER-OWN-PARAMS')
	public function testACaptureIsTypedThroughItsSubject(): Void {
		#if (sys || nodejs)
		Assert.equals(
			1,
			quickTakes(
				'final opt:haxe.ds.Option<D> = haxe.ds.Option.Some(this); switch opt { case Some(v): Reflect.setField(v, k, _m); case None: }'
			),
			'a library Option capture'
		);
		Assert.equals(
			1,
			quickTakes(
				'final e:haxe.ds.Either<D, Int> = haxe.ds.Either.Left(this); switch e { case Left(v): Reflect.setField(v, k, _m); case Right(_): }'
			),
			'a library Either capture'
		);
		Assert.equals(1, quickTakes('switch crate { case Wrap(Pack(v)): Reflect.setField(v, k, _m); case _: }'), 'a nested pattern');
		Assert.equals(
			1, quickTakes('switch gen { case Hold(v): Reflect.setField(v, k, _m); }'), "a parameter of the enum's own type parameter"
		);
		Assert.equals(
			1, quickTakes('switch twin { case Twice(v): Reflect.setField(v, k, _m); }'), 'a subject two enums of its name may be'
		);
		final crate: String = 'switch crate { case Pack(o): Reflect.setField(o, k, _m); case _: }';
		Assert.equals(0, quickTakes(crate), 'a capture its subject types');
		Assert.equals(
			1, found(crate).filter(f -> f.indexOf('D.alias (a capture of Crate.Pack, typed by its parameter)') != -1).length, 'named'
		);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/**
	 * Every name a run writes that makes an object of `Node`, or reads it as a class value, counts as making one: a
	 * typedef alias of it made or read as a value, an import alias of it made, a literal naming it handed to
	 * `Type.resolveClass`. A made name that resolves to no type may be an alias of it too; a std type, a class the run
	 * declares, a literal naming another class do not make one.
	 */
	@:pin('control') @:killer('M-TS-MAKES-RESOLVED') @:killer('M-TS-MAKES-LITERAL') @:killer('M-TS-MAKES-UNKNOWN')
	@:killer('M-TS-MAKES-STD') @:killer('M-TS-MAKES-ALIAS-NOTHING') @:killer('M-TS-MAKES-ALIAS-STD')
	@:killer('M-TS-MAKES-WILD') @:killer('M-TS-MAKES-BOUND') @:killer('M-TS-MAKES-USING')
	public function testEveryNameThatMakesTheClassMakesIt(): Void {
		#if (sys || nodejs)
		final use: String = 'n.targetObject = d; n.toTarget("_l", d._m);';
		final alias: String = 'typedef NA = Node<D>;';
		Assert.equals(1, nodeTakes(CLOSED, alias, 'final n:NA = new NA(); $use'), 'a typedef alias made');
		Assert.equals(1, nodeTakes(CLOSED, alias, 'final n:Node<D> = Type.createInstance(NA, []); $use'), 'a typedef alias as a value');
		Assert.equals(
			1, nodeTakes(CLOSED, '', 'final n:Node<D> = Type.createInstance(Type.resolveClass("Node"), []); $use'), 'a literal naming it'
		);
		Assert.equals(
			1, nodeTakes(CLOSED, 'typedef NB = Unseen<D>;', 'final x = new NB(); new V().toTarget("_l", d._m);'), 'an alias of nothing'
		);
		Assert.equals(1, nodeTakes(CLOSED, '', 'final x = new Mystery(); new V().toTarget("_l", d._m);'), 'a name nothing declares');
		Assert.equals(1, importAsTakes('import pkg.Node as NN;', 'final n:NN<D> = new NN<D>(); $use'), 'an import alias made');
		Assert.equals(0, importAsTakes('import pkg.Node as NN;', 'new V().toTarget("_l", d._m);'), 'an import alias not made');
		Assert.equals(
			1, importAsTakes('import pkg.NB;', 'final x = new NB(); new V().toTarget("_l", d._m);', 'typedef NB = Unseen<D>;'),
			'an imported alias of nothing'
		);
		Assert.equals(
			0, nodeTakes(CLOSED, 'typedef NM = Map<String, Int>;', 'final x = new NM(); new V().toTarget("_l", d._m);'),
			'an alias of a std type'
		);
		Assert.equals(0, importAsTakes('import somelib.*;', 'final x = new Widget(); new V().toTarget("_l", d._m);'), 'a library wildcard');
		Assert.equals(
			0, importAsTakes('#if sys import somelib.Gadget; #end', 'final x = new Gadget(); new V().toTarget("_l", d._m);'),
			'a guarded import'
		);
		Assert.equals(
			0,
			importAsTakes('import somelib.Gadget;', 'final x = new Gadget(); final y = new otherlib.Thing(); new V().toTarget("_l", d._m);'),
			'a library type imported or written out'
		);
		Assert.equals(0, importAsTakes('using haxe.io.Path;', 'final x = new Path("p"); new V().toTarget("_l", d._m);'), 'a using');
		Assert.equals(
			0, nodeTakes(CLOSED, '', 'final c = Type.resolveClass("Other"); new V().toTarget("_l", d._m);'), 'a literal naming another'
		);
		Assert.equals(
			0,
			nodeTakes(CLOSED, '', 'final m = new Map<String, Int>(); final s = new haxe.ds.StringMap<Int>(); new V().toTarget("_l", d._m);'),
			'std types made'
		);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/**
	 * A computed name on a value the run places on no class, storing what holds no lock: no value, a literal, a value of
	 * an unrelated class, a parameter every call of which hands one such (an optional parameter's absent argument
	 * included) — `_l` keeps its name, so the main thread's take of it waits for no worker, and the run names the writer
	 * with what it stores.
	 */
	@:pin('control') @:killer('M-TS-STORED-NOTHING') @:killer('M-TS-STORED-LITERAL') @:killer('M-TS-STORED-NULL')
	@:killer('M-TS-STORED-TYPED') @:killer('M-TS-STORED-UNRELATED') @:killer('M-TS-STORED-PARAMETER')
	@:killer('M-TS-STORED-KEPT-NOTICE') @:killer('M-TS-STORED-COUNTS') @:killer('M-TS-STORED-ENUM') @:killer('M-TS-STORED-BASIC')
	@:killer('M-TS-STORED-CATCH-ALL')
	public function testAWriteThatStoresNoLockKeepsTheLockNames(): Void {
		#if (sys || nodejs)
		Assert.equals(0, helperTakes(SEALED, '', ''), 'no call hands it anything');
		Assert.equals(0, helperTakes(SEALED, '', 'Help.assign(d, "x", "text");'), 'a string');
		Assert.equals(0, helperTakes(SEALED, '', 'Help.assign(d, "x", 5);'), 'a number');
		Assert.equals(0, helperTakes(SEALED, '', 'Help.assign(d, "x", null);'), 'null');
		Assert.equals(0, helperTakes(SEALED, '', 'final s:String = "a"; Help.assign(d, "x", s);'), 'a typed String');
		Assert.equals(0, helperTakes(SEALED, '', 'Help.assign(d, "x", new Other());'), 'an object of a class no lock is');
		Assert.equals(0, helperTakes(SEALED, '', 'final c:Color = Color.Red; Help.assign(d, "x", c);'), 'an enum value');
		Assert.equals(0, helperTakes(SEALED, '', 'final k:String = "x"; Reflect.deleteField(bag, k);'), 'a delete');
		Assert.equals(
			0, helperTakes(SEALED, PUT, 'Help.put(d, "x", 1); Help.put(d, "y");'), 'a parameter handed numbers, or nothing at all'
		);
		Assert.equals(
			1,
			helperFindings(SEALED, '', 'Help.assign(d, "x", "text");')
				.filter(f -> f.indexOf('kept off every lock member') != -1 && f.indexOf('Help.assign (it stores String)') != -1)
				.length,
			'the run names the writer and what it stores'
		);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/**
	 * What a write stores may be a lock whenever a lock may have reached a value of no lock type: stored in a `Dynamic`
	 * field, an `Array<Dynamic>`, a structure, a `Map<String, Dynamic>`, handed to a `Dynamic` parameter, cast, returned as
	 * `Any` — or be one, declared so: each unseals `_l` as before, named in the run's notice.
	 */
	@:pin('control') @:killer('M-TS-STORED-ANY') @:killer('M-TS-STORED-RELATED') @:killer('M-TS-STORED-ARGUMENTS')
	public function testAWriteThatMayStoreALockUnsealsAsBefore(): Void {
		#if (sys || nodejs)
		Assert.equals(1, helperTakes(SEALED, '', 'final m:Mutex = new Mutex(); Help.assign(d, "x", m);'), 'a lock');
		Assert.equals(1, helperTakes(SEALED, '', 'Help.assign(d, "x", new Sub());'), 'a subclass of the lock');
		Assert.equals(1, helperTakes(SEALED, '', 'bag = new Mutex(); Help.assign(d, "x", bag);'), 'a Dynamic field');
		Assert.equals(
			1, helperTakes(SEALED, '', 'final a:Array<Dynamic> = [new Mutex()]; Help.assign(d, "x", a[0]);'), 'an Array<Dynamic>'
		);
		Assert.equals(1, helperTakes(SEALED, '', 'final s:{ m:Dynamic } = { m: new Mutex() }; Help.assign(d, "x", s.m);'), 'a structure');
		Assert.equals(
			1, helperTakes(SEALED, '', 'final s:Map<String, Dynamic> = ["m" => new Mutex()]; Help.assign(d, "x", s["m"]);'),
			'a Map<String, Dynamic>'
		);
		Assert.equals(1, helperTakes(SEALED, PASS, 'Help.pass(new Mutex());'), 'handed to a Dynamic parameter');
		Assert.equals(1, helperTakes(SEALED, '', 'Help.assign(d, "x", cast new Mutex());'), 'a cast');
		Assert.equals(1, helperTakes(SEALED, '', 'final set = Reflect.setField; set(bag, "x", 1);'), 'a reflective write handed on');
		Assert.equals(
			1, helperTakes(SEALED, 'public static function any():Any return new Mutex();', 'Help.assign(d, "x", Help.any());'), 'Any'
		);
		Assert.equals(
			1,
			helperFindings(SEALED, '', 'bag = new Mutex(); Help.assign(d, "x", bag);')
				.filter(f -> f.indexOf('so no lock is named by its member: Help.assign') != -1)
				.length,
			'the run names the writer'
		);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/**
	 * A parameter is followed into its calls only when the run sees every one of them: in a run over a closed project
	 * declaring which classes' methods a computed name may obtain, never for a function handed on as a value, called by a
	 * name the graph does not resolve, or spelled by a literal a reflective read may obtain it by. An optional parameter
	 * before it lets an argument move along.
	 */
	@:pin('control') @:killer('M-TS-STORED-CALLERS') @:killer('M-TS-STORED-COMPLETE') @:killer('M-TS-STORED-HOLDERS')
	@:killer('M-TS-STORED-SPELLED') @:killer('M-TS-STORED-GLOB') @:killer('M-TS-STORED-SKIPPED') @:killer('M-TS-STORED-REF')
	public function testAParameterIsFollowedOnlyWhereEveryCallIsSeen(): Void {
		#if (sys || nodejs)
		Assert.equals(1, helperTakes(CLOSED, '', ''), 'no reflectiveMethodHolders');
		Assert.equals(1, helperTakes('{"reflectiveMethodHolders":["nothing.*"],"rules":{$RULE}}}', '', ''), 'no closed project');
		Assert.equals(
			1,
			helperTakes(
				'{"reflectiveMethodHolders":["nothing.*"],"rules":{$RULE}}}', '',
				'final k:String = "x"; Reflect.setField(bag, k, new Other());'
			),
			'a class in a run that may not see every class'
		);
		Assert.equals(1, helperTakes(SEALED, '', 'final f = Help.assign; f(d, "x", "text");'), 'a function value');
		Assert.equals(1, helperTakes(SEALED, '', 'final o:Dynamic = d; o.assign(d, "x", "text");'), 'an unresolved call of its name');
		Assert.equals(1, helperTakes(SEALED, '', 'Help.assign(d, "x", "text"); Reflect.field(Help, "assign");'), 'a literal names it');
		Assert.equals(
			1, helperTakes('{"reflectiveMethodHolders":["Help"],"rules":{$RULE,"closedWorld":true}}}', '', ''),
			'its class may lend its methods'
		);
		Assert.equals(1, helperTakes(SEALED, SKIP, 'Help.skip(new Mutex());'), 'a skipped optional parameter');
		Assert.equals(0, helperTakes(SEALED, SKIP, 'Help.skip(1, "text");'), 'nothing skipped');
		#else
		Assert.pass('non-sys target');
		#end
	}

	/**
	 * What a write stores costs only the lock members of a type it may be a lock of: a `Gate` stored unseals `_g`, never
	 * the `Mutex` member `_l`; a `Mutex` stored, never `_g`.
	 */
	@:pin('control') @:killer('M-TS-STORED-MEMBER-TYPE') @:killer('M-TS-STORED-MARKED') @:killer('M-TS-STORED-TYPED-NOTICE')
	public function testWhatAWriteStoresUnsealsOnlyTheLocksOfItsType(): Void {
		#if (sys || nodejs)
		final gate: Array<String> = gateFindings('Help.assign(d, "x", new Gate());');
		Assert.equals(0, gate.filter(f -> f.indexOf('D.quick -> Mutex.acquire') != -1).length, 'the Mutex member keeps its name');
		Assert.equals(1, gate.filter(f -> f.indexOf('D.gate -> Gate.lock') != -1).length, 'the Gate member loses it');
		Assert.equals(
			1, gate.filter(f -> f.indexOf('no such member names its lock: Help.assign (it stores Gate)') != -1).length,
			'the run names the writer'
		);
		final mutex: Array<String> = gateFindings('Help.assign(d, "x", new Mutex());');
		Assert.equals(1, mutex.filter(f -> f.indexOf('D.quick -> Mutex.acquire') != -1).length, 'the Mutex member loses its name');
		Assert.equals(0, mutex.filter(f -> f.indexOf('D.gate -> Gate.lock') != -1).length, 'the Gate member keeps it');
		#else
		Assert.pass('non-sys target');
		#end
	}

	#if (sys || nodejs)
	/** `Help.put`, handing an optional parameter on to `Help.assign`. */
	private static inline final PUT: String = 'public static function put(o:Dynamic, k:String, ?v:Dynamic):Void assign(o, k, v);';

	/** `Help.pass`, handing a `Dynamic` parameter on to `Help.assign`. */
	private static inline final PASS: String = 'public static function pass(x:Dynamic):Void assign(D.bag, "x", x);';

	/** `Help.skip`, whose stored parameter comes after an optional one. */
	private static inline final SKIP: String = 'public static function skip(?n:Int, v:Dynamic):Void assign(D.bag, "x", v);';

	/** How many findings of `helperFindings` report the main thread's take of `_l` in `D.quick`. */
	private static function helperTakes(config: String, helpers: String, use: String): Int {
		return helperFindings(config, helpers, use).filter(f -> f.indexOf('D.quick -> Mutex.acquire') != -1).length;
	}

	/**
	 * The findings of a run under `config` in which `Help.assign` writes a computed name on a `Dynamic` value, `Help`
	 * declares `helpers` beside it, and `D.main` runs `use` on the main thread while a worker holds `_m` across a sleep and
	 * the main thread takes `_l`.
	 */
	private static function helperFindings(config: String, helpers: String, use: String): Array<String> {
		return [
			for (v in ThreadSafetyCheckTest.violations(config, [
				ThreadSafetyCheckTest.MUTEX,
				'class Runner { public static function create(fn:()->Void):Void {} }',
				'class Other { public function new() {} }',
				'class Sub extends Mutex { public function new() { super(); } }',
				'enum Color { Red; }',
				'class Help { public static function assign(o:Dynamic, k:String, v:Dynamic):Void Reflect.setField(o, k, v); $helpers }',
				'class D { var _l:Mutex = new Mutex(); final _m:Mutex = new Mutex(); public static var bag:Dynamic = null;'
				+ ' public function new() {} public function work():Void { _m.acquire(); Sys.sleep(1); _m.release(); }'
				+ ' public function quick():Void { _l.acquire(); _l.release(); }'
				+ ' public static function main():Void { final d:D = new D(); Runner.create(() -> d.work()); $use d.quick(); } }'
			])) v.message
		];
	}

	/**
	 * The findings of a closed run in which `Help.assign` writes a computed name on a `Dynamic` value, a worker holds the
	 * `Mutex` `_m` and the `Gate` `_h` across a sleep, the main thread runs `use` and takes `_l` and `_g`.
	 */
	private static function gateFindings(use: String): Array<String> {
		return [
			for (v in ThreadSafetyCheckTest.violations(
				'{"reflectiveClasses":["nothing.*"],"reflectiveMethodHolders":["nothing.*"],"rules":{"thread-safety":{'
				+ '"sinks":["Mutex.acquire","Gate.lock","Sys.sleep"],"spawns":["Runner.create"],'
				+ '"lockPairs":["Mutex.acquire/release","Gate.lock/unlock"],"closedWorld":true}}}',
				[
					ThreadSafetyCheckTest.MUTEX,
					'class Gate { public function new() {} public function lock():Void {} public function unlock():Void {} }',
					'class Runner { public static function create(fn:()->Void):Void {} }',
					'class Help { public static function assign(o:Dynamic, k:String, v:Dynamic):Void Reflect.setField(o, k, v); }',
					'class D { var _l:Mutex = new Mutex(); final _m:Mutex = new Mutex(); var _g:Gate = new Gate(); final _h:Gate = new Gate();'
					+ ' public function new() {}'
					+ ' public function work():Void { _m.acquire(); _h.lock(); Sys.sleep(1); _h.unlock(); _m.release(); }'
					+ ' public function quick():Void { _l.acquire(); _l.release(); }'
					+ ' public function gate():Void { _g.lock(); _g.unlock(); }'
					+ ' public static function main():Void { final d:D = new D(); Runner.create(() -> d.work()); $use d.quick(); d.gate(); } }'
				]
			)) v.message
		];
	}

	/**
	 * How many findings report the main thread's take of `_l` in `D.quick` when `Node` sits in the package `pkg` beside
	 * `beside`, `V` imports it, and `D`'s file, under `imports`, runs `use`.
	 */
	private static function importAsTakes(imports: String, use: String, beside: String = ''): Int {
		return [
			for (v in ThreadSafetyCheckTest.violations(CLOSED, [
				ThreadSafetyCheckTest.MUTEX,
				'class Runner { public static function create(fn:()->Void):Void {} }',
				'package pkg; class Node<T> { public var targetObject:T = null; public function new() {}'
				+ ' public function toTarget(k:String, m:Mutex):Void Reflect.setField(targetObject, k, m); } $beside',
				'import pkg.Node; final class V extends Node<Void> {}',
				'$imports import pkg.Node; class D { var _l:Mutex = new Mutex(); final _m:Mutex = new Mutex(); public function new() {}'
				+ ' public function work():Void { _m.acquire(); Sys.sleep(1); _m.release(); }'
				+ ' public function quick():Void { _l.acquire(); _l.release(); }'
				+ ' public static function main():Void { final d:D = new D(); Runner.create(() -> d.work()); $use d.quick(); } }'
			])) if (v.message.indexOf('D.quick -> Mutex.acquire') != -1) v.message
		].length;
	}

	/**
	 * The findings of a run in which a worker holds `_l` across a sleep, the main thread takes it, holds it into a throw,
	 * and runs `write` in `D.alias(k, m)` first.
	 */
	private static function unsealedFindings(write: String): Array<String> {
		return [
			for (v in ThreadSafetyCheckTest.violations('{"rules":{$RULE}}}', [
				ThreadSafetyCheckTest.MUTEX,
				'class Runner { public static function create(fn:()->Void):Void {} }',
				'class D { var _l:Mutex = new Mutex(); public static final arr:Array<D> = []; public function new() {}'
				+ ' public function work():Void { _l.acquire(); Sys.sleep(1); _l.release(); }'
				+ ' public function alias(k:String, m:Mutex):Void { $write }'
				+ ' public function quick():Void { _l.acquire(); _l.release(); }'
				+ ' public function risky():Void { _l.acquire(); throw "x"; }'
				+ ' public static function main():Void { final d:D = new D(); arr.push(d); Runner.create(() -> d.work());'
				+ ' d.alias("_l", new Mutex()); d.quick(); d.risky(); } }'
			])) v.message
		];
	}

	/** How many findings of `found(alias)` report the main thread's take of `_l` in `D.quick`. */
	private static function quickTakes(alias: String): Int {
		return found(alias).filter(f -> f.indexOf('D.quick -> Mutex.acquire') != -1).length;
	}

	/**
	 * The findings of a run in which `D.alias(k)` runs `alias` on the main thread while a worker holds `_m` across a
	 * sleep and the main thread takes `_l`.
	 */
	private static function found(alias: String): Array<String> {
		return [
			for (v in ThreadSafetyCheckTest.violations('{"rules":{$RULE}}}', [
				ThreadSafetyCheckTest.MUTEX,
				'class Runner { public static function create(fn:()->Void):Void {} }',
				'class Other { public function new() {} }',
				'enum Crate { Pack(o:Other); Wrap(s:Shelf); } enum Shelf { Pack(d:D); } enum Mine { Some(o:Other); Left(o:Other); }',
				'enum Gen<Other> { Hold(x:Other); } enum Twin { Twice(o:Other); }',
				'enum Twin { Twice(d:D); }',
				'enum Box { Holder(d:D); Bag(m:Map<String, Mutex>); Pack(d:D); }',
				'class D { var _l:Mutex = new Mutex(); final _m:Mutex = new Mutex();'
				+ ' public static final owners:haxe.ds.List<D> = new haxe.ds.List<D>(); public static final arr:Array<D> = [];'
				+ ' public static var box:Box = null; public static var crate:Crate = null;'
				+ ' public static var gen:Gen<D> = null; public static var twin:Twin = null; public function new() {}'
				+ ' public function work():Void { _m.acquire(); Sys.sleep(1); _m.release(); }'
				+ ' public function alias(k:String):Void { $alias }' + ' public function quick():Void { _l.acquire(); _l.release(); }'
				+ ' public static function main():Void { final d:D = new D(); owners.add(d); arr.push(d);'
				+ ' Runner.create(() -> d.work()); d.alias("_l"); d.quick(); } }'
			])) v.message
		];
	}

	/** How many findings of `nodeFindings` report the main thread's take of `_l` in `D.quick`. */
	private static function nodeTakes(config: String, classes: String, use: String, members: String = ''): Int {
		return nodeFindings(config, classes, use, members).filter(f -> f.indexOf('D.quick -> Mutex.acquire') != -1).length;
	}

	/**
	 * The findings of a run under `config` over `Node<T>`, whose `toTarget` writes `targetObject` by a computed name, its
	 * subclasses `V` (`Void`, a `final` class) and `P<X:Other>`, `classes` beside them, `members` among its own, and `D`
	 * running `use` on the main thread while a worker holds `_m` across a sleep and the main thread takes `_l`.
	 */
	private static function nodeFindings(config: String, classes: String, use: String, members: String = ''): Array<String> {
		return [
			for (v in ThreadSafetyCheckTest.violations(config, [
				ThreadSafetyCheckTest.MUTEX,
				'class Runner { public static function create(fn:()->Void):Void {} }',
				'class Other { public function new() {} }',
				'class Node<T> { public var targetObject:T = null; public function new() {}'
				+ ' public function toTarget(k:String, m:Mutex):Void Reflect.setField(targetObject, k, m);'
				+ ' public static function poke<X:Other>(o:X, k:String, m:Mutex):Void Reflect.setField(o, k, m); $members }',
				'final class V extends Node<Void> {} class P<X:Other> extends Node<X> {} $classes',
				'class D { var _l:Mutex = new Mutex(); final _m:Mutex = new Mutex(); public function new() {}'
				+ ' public function work():Void { _m.acquire(); Sys.sleep(1); _m.release(); }'
				+ ' public function quick():Void { _l.acquire(); _l.release(); }'
				+ ' public static function main():Void { final d:D = new D(); Runner.create(() -> d.work()); Node.poke(new Other(), "x", null);'
				+ ' $use d.quick(); } }'
			])) v.message
		];
	}
	#end

}
