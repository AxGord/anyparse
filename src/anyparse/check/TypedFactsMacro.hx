package anyparse.check;

#if macro
import haxe.Json;
import haxe.macro.Context;
import haxe.macro.Expr.MetadataEntry;
import haxe.macro.Expr.Position;
import haxe.macro.Type;
import sys.io.File;
import sys.io.FileOutput;

/**
 * The compile-time half of `TypedFactsProbe`: an `onAfterTyping` hook that writes what the compiler typed as JSON Lines
 * to a file. The records and the type-string grammar are specified in `TypedFactsProbe`; this class only produces them,
 * and runs in the macro context of the compile it describes, never in anyparse. Every line is rendered by hand: the
 * interpreted `Json.stringify` cost more than the whole walk.
 */
@:nullSafety(Strict)
final class TypedFactsMacro {

	/** The facts format version the header line carries. */
	private static inline final VERSION: Int = 1;

	/** Deeper type nesting prints as unknown, so a recursive structure cannot grow a line without bound. */
	private static inline final TYPE_DEPTH: Int = 8;

	/** This module: the probe itself is not the build's code. */
	private static inline final OWN_MODULE: String = 'anyparse.check.TypedFactsMacro';

	/** Whether each class path names a type parameter, decided once per path: reading a `Ref` decodes the whole class. */
	private static final typeParams: Map<String, Bool> = [];

	private static var installed: Bool = false;

	/** Nodes written, for the closing record. */
	public var nodes: Int = 0;

	private final _files: Map<String, Int> = [];
	private final _taken: Map<String, Bool> = [];
	private final _out: FileOutput;

	private var _fileCount: Int = 0;
	private var _types: Int = 0;

	private function new(out: FileOutput) {
		this._out = out;
	}

	/** One line. */
	public function line(text: String): Void {
		_out.writeString(text);
		_out.writeString('\n');
	}

	/**
	 * `p` as `[min, max]` when it lies in `home`, the file of the record carrying it, and as `[file index, min, max]`
	 * otherwise, that file announced by a `file` record on its first use. A record without a foreign position is thereby
	 * the same text in every compile that typed the same code.
	 */
	public function pos(p: Position, home: String): String {
		final info: { min: Int, max: Int, file: String } = Context.getPosInfos(p);
		if (info.file == home) return '[${info.min},${info.max}]';
		var index: Null<Int> = _files[info.file];
		if (index == null) {
			index = _fileCount++;
			_files[info.file] = index;
			line('{"k":"file","i":$index,"path":${Json.stringify(info.file)}}');
		}
		return '[$index,${info.min},${info.max}]';
	}

	/** `base`, made unique among the node ids this compile emitted. */
	public function uniqueId(base: String): String {
		var id: String = base;
		var n: Int = 1;
		while (_taken.exists(id)) id = '$base#${n++}';
		_taken[id] = true;
		return id;
	}

	private function moduleType(t: ModuleType): Void {
		switch t {
			case TClassDecl(r):
				final c: ClassType = r.get();
				if (c.module == OWN_MODULE) return;
				switch c.kind {
					case KGenericInstance(_, _) | KTypeParameter(_) | KMacroType | KGenericBuild | KExpr(_):
						return;
					case _:
				}
				classType(c);
			case TEnumDecl(r):
				final e: EnumType = r.get();
				final ctors: Array<String> = [
					for (name in e.names) '{"n":${q(name)},"t":${q(typeString(e.constructs[name]?.type, 0))}}'
				];
				typeLine(e.pack, e.name, 'enum', e.pos, e.params, e.meta.get(), e.isExtern, [',"ctors":' + arr(ctors)]);
			case TTypeDecl(r):
				final d: DefType = r.get();
				typeLine(d.pack, d.name, 'typedef', d.pos, d.params, d.meta.get(), d.isExtern, [',"target":' + q(typeString(d.type, 0))]);
			case TAbstract(r):
				final a: AbstractType = r.get();
				final extra: Array<String> = [
					',"under":' + q(typeString(a.type, 0)),
					',"from":' + typeList([for (f in a.from) f.t]),
					',"to":' + typeList([for (f in a.to) f.t])
				];
				final impl: Null<Ref<ClassType>> = a.impl;
				if (impl != null) extra.push(',"impl":' + q(impl.toString()));
				typeLine(a.pack, a.name, 'abstract', a.pos, a.params, a.meta.get(), a.isExtern, extra);
		}
	}

	private function classType(c: ClassType): Void {
		final id: String = typeId(c.pack, c.name);
		final extra: Array<String> = [];
		final sup: Null<{ t: Ref<ClassType>, params: Array<Type> }> = c.superClass;
		if (sup != null) extra.push(',"sup":' + q(instString(sup.t, sup.params, 0)));
		if (c.interfaces.length > 0) extra.push(',"ifaces":' + arr([for (i in c.interfaces) q(instString(i.t, i.params, 0))]));
		final kind: String = switch c.kind {
			case KAbstractImpl(a):
				extra.push(',"abs":' + q(a.toString()));
				'impl';
			case _ if (c.isInterface): 'interface';
			case _: 'class';
		};
		final members: Array<{ f: ClassField, s: Bool }> = [for (f in c.fields.get()) { f: f, s: false }];
		for (f in c.statics.get()) members.push({ f: f, s: true });
		final ctor: Null<Ref<ClassField>> = c.constructor;
		if (ctor != null) members.push({ f: ctor.get(), s: false });
		extra.push(',"fields":' + arr([for (m in members) fieldRecord(m.f, m.s, fileOf(c.pos))]));
		typeLine(c.pack, c.name, kind, c.pos, c.params, c.meta.get(), c.isExtern, extra);
		for (m in members) {
			final body: Null<TypedExpr> = m.f.expr();
			if (body == null) continue;
			final nodeKind: String = switch m.f.kind {
				case FMethod(_) if (m.f.name == 'new' && !m.s): 'ctor';
				case FMethod(_): 'method';
				case FVar(_, _): 'var';
			};
			new TypedFactsWalk(this, '$id.${m.f.name}', nodeKind, id, m.s, typeString(m.f.type, 0), null, []).root(body);
		}
	}

	private function fieldRecord(f: ClassField, isStatic: Bool, home: String): String {
		final kind: String = switch f.kind {
			case FVar(read, write): 'var(${access(read)},${access(write)})';
			case FMethod(MethNormal): 'method';
			case FMethod(MethInline): 'inline';
			case FMethod(MethDynamic): 'dynamic';
			case FMethod(MethMacro): 'macro';
		};
		final out: StringBuf = new StringBuf();
		out.add('{"n":${q(f.name)},"k":"$kind","t":${q(typeString(f.type, 0))},"p":${pos(f.pos, home)}');
		if (isStatic) out.add(',"s":true');
		if (f.isFinal) out.add(',"fin":true');
		if (f.isExtern) out.add(',"ext":true');
		final overloads: Int = f.overloads.get().length;
		if (overloads > 0) out.add(',"over":$overloads');
		out.add(metaList(f.meta.get()));
		out.add('}');
		return out.toString();
	}

	private function typeLine(
		pack: Array<String>, name: String, kind: String, p: Position, params: Array<TypeParameter>, meta: Array<MetadataEntry>,
		isExtern: Bool, extra: Array<String>
	): Void {
		_types++;
		final home: String = fileOf(p);
		final out: StringBuf = new StringBuf();
		out.add('{"k":"type","id":${q(typeId(pack, name))},"f":${q(home)},"p":${pos(p, home)},"kind":"$kind","pack":${q(pack.join('.'))}');
		if (params.length > 0) out.add(',"params":' + arr([for (tp in params) q(tp.name)]));
		out.add(metaList(meta));
		if (isExtern) out.add(',"ext":true');
		for (e in extra) out.add(e);
		out.add('}');
		line(out.toString());
	}

	/** Install the hook that writes the facts of the compile to `path` once typing ended; the last line is an `end` record. */
	public static function run(path: String): Void {
		if (installed) return;
		installed = true;
		Context.onAfterTyping(moduleTypes -> {
			final writer: TypedFactsMacro = new TypedFactsMacro(File.write(path, false));
			writer.line('{"k":"facts","v":$VERSION,"inline":${!Context.defined('no-inline')}}');
			for (t in moduleTypes) writer.moduleType(t);
			writer.line('{"k":"end","nodes":${writer.nodes},"types":${writer._types}}');
			writer._out.close();
		});
	}

	/** The file `p` lies in. */
	public static function fileOf(p: Position): String {
		return Context.getPosInfos(p).file;
	}

	/** `s` as a JSON string. Names, paths and type strings carry no control character, so only a quote or a backslash needs the printer. */
	public static function q(s: String): String {
		return s.indexOf('"') < 0 && s.indexOf('\\') < 0 ? '"$s"' : Json.stringify(s);
	}

	/** `items`, each already JSON, as a JSON array. */
	public static function arr(items: Array<String>): String {
		return '[' + items.join(',') + ']';
	}

	/** The id of a type: its package, then its name, which is how the compiler names it — a private type's package ends in its module. */
	public static function typeId(pack: Array<String>, name: String): String {
		return pack.length == 0 ? name : pack.join('.') + '.' + name;
	}

	/** `t` in the facts type grammar (`TypedFactsProbe`). */
	public static function typeString(t: Null<Type>, depth: Int): String {
		if (t == null || depth > TYPE_DEPTH) return '?';
		return switch t {
			case TMono(r):
				final bound: Null<Type> = r.get();
				bound == null ? '?' : typeString(bound, depth);
			case TLazy(f): typeString(f(), depth);
			case TInst(c, params): instString(c, params, depth);
			case TEnum(e, params): e.toString() + paramString(params, depth);
			case TType(d, params): d.toString() + paramString(params, depth);
			case TAbstract(a, params): a.toString() + paramString(params, depth);
			case TDynamic(null): 'Dynamic';
			case TDynamic(inner): 'Dynamic<' + typeString(inner, depth + 1) + '>';
			case TFun(args, ret):
				'(' + [for (a in args) (a.opt ? '?' : '') + typeString(a.t, depth + 1)].join(',') + ')->' + typeString(ret, depth + 1);
			case TAnonymous(a):
				final anon: AnonType = a.get();
				switch anon.status {
					case AClassStatics(c): 'Class<' + c.toString() + '>';
					case AEnumStatics(e): 'Enum<' + e.toString() + '>';
					case AAbstractStatics(ab): 'Abstract<' + ab.toString() + '>';
					case _:
						final fields: Array<ClassField> = anon.fields.copy();
						fields.sort((x, y) -> x.name < y.name ? -1 : x.name > y.name ? 1 : 0);
						'{'
							+ [
								for (f in fields) (f.meta.has(':optional') ? '?' : '') + f.name + ':' + typeString(f.type, depth + 1)
							].join(',') + '}';
				}
		};
	}

	private static function instString(c: Ref<ClassType>, params: Array<Type>, depth: Int): String {
		final path: String = c.toString();
		var isParam: Null<Bool> = typeParams[path];
		if (isParam == null) {
			isParam = c.get().kind.match(KTypeParameter(_));
			typeParams[path] = isParam;
		}
		return isParam ? '$' + path : path + paramString(params, depth);
	}

	private static function paramString(params: Array<Type>, depth: Int): String {
		return params.length == 0 ? '' : '<' + [for (p in params) typeString(p, depth + 1)].join(',') + '>';
	}

	private static function typeList(list: Array<Type>): String {
		return arr([for (t in list) q(typeString(t, 0))]);
	}

	private static function metaList(meta: Array<MetadataEntry>): String {
		return meta.length == 0 ? '' : ',"meta":' + arr([for (m in meta) q(m.name)]);
	}

	private static function access(a: VarAccess): String {
		return switch a {
			case AccNormal: 'default';
			case AccNo: 'null';
			case AccNever: 'never';
			case AccResolve: 'resolve';
			case AccCall: 'call';
			case AccInline: 'inline';
			case AccRequire(_, _): 'require';
			case AccCtor: 'ctor';
		};
	}

}
#end
