package anyparse.grammar.haxe;

/**
 * Marker class for the macro-generated query walker of `HxModule`.
 *
 * Sibling to `HaxeModuleSpanParser` (which generates the parser producing the
 * paired `*S` AST this walks) and to `HxModuleAst` (which generates the deep
 * transform over the plain AST). Drives the
 * `Build.buildQueryWalker(HxModule)` codegen path.
 *
 * The public `walk(root, withTypeRefs)` returns the `QueryNode` children of the
 * module, which `HaxeQueryPlugin.parseFile` wraps in the `module` root. Per
 * grammar rule the macro also emits the private `_walk` / `_nameOf` /
 * `_typeRefs` trio the entry recurses through - see `QueryWalkerLowering` for
 * what each does and why.
 *
 * This replaces a hand-written reflective walk over the same values. Every
 * decision it now makes at compile time (which kind a rule is, what fields a
 * struct has, which enum ctor a value carries, where the span sits) was a
 * `Type.typeof` / `Reflect.fields` / `Type.enumParameters` / `Std.isOfType`
 * probe rediscovering the grammar at run time. Beyond the type safety, the
 * generated switch is exhaustive: adding a grammar ctor without teaching the
 * walker about it is now a compile error rather than a silently missing node.
 */
@:build(anyparse.macro.Build.buildQueryWalker(anyparse.grammar.haxe.HxModule))
@:nullSafety(Strict)
class HaxeQueryWalker {}
