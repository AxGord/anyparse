package unit.query.graph;

import anyparse.query.CallGraph;

/**
 * A three-type project in two packages for the graph suites: a member calling another twice, a lambda
 * calling out, a constructor running its type's field initializers, a static-extension import inside one
 * package, and an import back the other way.
 */
@:nullSafety(Strict)
final class GraphFixture {

	public static final FILES: Array<{ file: String, source: String }> = [
		{
			file: 'pkg/a/Alpha.hx',
			source: [
				'package pkg.a;',
				'',
				'import pkg.b.Beta;',
				'',
				'class Alpha {',
				'\tpublic function run():Void {',
				'\t\tstep();',
				'\t\tstep();',
				'\t\tfinal b:Beta = new Beta();',
				'\t\tb.work();',
				'\t}',
				'',
				'\tfunction step():Void {',
				'\t\tfinal f:() -> Beta = () -> Beta.make();',
				'\t\tf();',
				'\t}',
				'}',
				''
			].join('\n')
		},
		{
			file: 'pkg/b/Beta.hx',
			source: [
				'package pkg.b;',
				'',
				'using pkg.b.Gamma;',
				'',
				'class Beta {',
				'\tvar count:Int = 0;',
				'',
				'\tpublic function new() {}',
				'',
				'\tpublic function work():Void {',
				'\t\tcount++;',
				'\t\tGamma.tick();',
				'\t}',
				'',
				'\tpublic static function make():Beta {',
				'\t\treturn new Beta();',
				'\t}',
				'}',
				''
			].join('\n')
		},
		{
			file: 'pkg/b/Gamma.hx',
			source: [
				'package pkg.b;',
				'',
				'import pkg.a.Alpha;',
				'',
				'class Gamma {',
				'\tpublic static function tick():Void {}',
				'',
				'\tpublic static function back():Void {',
				'\t\tnew Alpha().run();',
				'\t}',
				'}',
				''
			].join('\n')
		}
	];

	/** `callees Alpha.run --depth 3` as Mermaid: the lambda folded into `step`, `<init>` written literally. */
	public static final CALLEES_MERMAID: String = [
		'%% callees Alpha.run --depth 3',
		'flowchart LR',
		'subgraph p_pkg_da[pkg.a]',
		'    subgraph t_pkg_da_dAlpha[Alpha]',
		'        m_pkg_da_dAlpha_drun(run)',
		'        m_pkg_da_dAlpha_dstep(step)',
		'    end',
		'end',
		'subgraph p_pkg_db[pkg.b]',
		'    subgraph t_pkg_db_dBeta[Beta]',
		'        m_pkg_db_dBeta_d_x3C_init_x3E_("#lt;init#gt;")',
		'        m_pkg_db_dBeta_dmake(make)',
		'        m_pkg_db_dBeta_dnew(new)',
		'        m_pkg_db_dBeta_dwork(work)',
		'    end',
		'    subgraph t_pkg_db_dGamma[Gamma]',
		'        m_pkg_db_dGamma_dtick(tick)',
		'    end',
		'end',
		'm_pkg_da_dAlpha_drun -->|2| m_pkg_da_dAlpha_dstep',
		'm_pkg_da_dAlpha_drun ==>|new| m_pkg_db_dBeta_dnew',
		'm_pkg_da_dAlpha_drun --> m_pkg_db_dBeta_dwork',
		'm_pkg_da_dAlpha_dstep --> m_pkg_db_dBeta_dmake',
		'm_pkg_db_dBeta_dmake ==>|new| m_pkg_db_dBeta_dnew',
		'm_pkg_db_dBeta_dnew --> m_pkg_db_dBeta_d_x3C_init_x3E_',
		'm_pkg_db_dBeta_dwork --> m_pkg_db_dGamma_dtick',
		'classDef focus stroke-width:3px',
		'class m_pkg_da_dAlpha_drun focus',
		''
	].join('\n');

	/**
	 * One module at the earlier of two versions: `run` calls `step` twice, `gone` is still there, `B` calls `run`.
	 */
	public static final DIFF_BEFORE: String = [
		'package p;',
		'class A {',
		'\tpublic function new() {}',
		'\tpublic function run():Void { step(); step(); helper(); run(); }',
		'\tfunction step():Void {}',
		'\tfunction helper():Void {}',
		'\tfunction gone():Void { step(); }',
		'}',
		'class B {',
		'\tpublic function work():Void { new A().run(); }',
		'\tpublic function idle():Void {}',
		'}',
		''
	].join('\n');

	/**
	 * The later version: `run` changed and calls `step` once and the new `fresh`,
	 * `step` laid out anew, `gone` removed, the new type `C` calls `run`.
	 */
	public static final DIFF_AFTER: String = [
		'package p;',
		'class A {',
		'\tpublic function new() {}',
		'\tpublic function run():Void { step(); helper(); fresh(); run(); }',
		'\tfunction step() : Void {   }',
		'\tfunction helper():Void {}',
		'\tfunction fresh():Void {}',
		'}',
		'class B {',
		'\tpublic function work():Void { new A().run(); }',
		'\tpublic function idle():Void {}',
		'}',
		'class C {',
		'\tpublic function go():Void { new A().run(); }',
		'}',
		''
	].join('\n');

	/** `DIFF_BEFORE` against `DIFF_AFTER` as the text report reads it, `run` the one member whose text changed. */
	public static final DIFF_REPORT: String = [
		'8 node(s), 7 edge(s), 0 mutual pair(s)',
		'changed:',
		'  + member p.A.fresh',
		'  - member p.A.gone',
		'  ~ member p.A.run',
		'  + member p.C.go',
		'  + type p.C',
		'edges:',
		'  ~ p.A.run -> p.A  call 2 (was 3)',
		'  - p.A.gone -> p.A  call 1',
		'  + p.A.run -> p.A.fresh  call 1',
		'    p.A.run -> p.A.run  call 1',
		'  + p.C.go -> p.A.run  call 1',
		'  + p.C.go -> p.A  new 1',
		'    p.B -> p.A.run  call 1',
		''
	].join('\n');

	/** The call graph over `FILES`. */
	public static function calls(): CallGraph {
		return CallGraph.build(FILES, new HaxeQueryPlugin());
	}

}
