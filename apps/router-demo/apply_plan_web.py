#!/usr/bin/env python3
import json
import hashlib
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
LATEST = ROOT / "artifacts" / "runs" / "LATEST"
GENERATED = ROOT / "apps" / "generated"

TEMPLATE = """import Link from "next/link";

const APP_TITLE = "__APP_TITLE__";
const TAGLINE = "__TAGLINE__";
const CURRENT = "__CURRENT__";
const NAV = __NAV_JSON__;

export default function Page() {
  return (
    <div className="min-h-screen bg-white text-zinc-900">
      <header className="sticky top-0 z-10 border-b bg-white/80 backdrop-blur">
        <div className="mx-auto flex max-w-5xl items-center justify-between px-6 py-4">
          <div className="text-sm font-semibold tracking-tight">{APP_TITLE}</div>
          <nav className="flex items-center gap-4 text-sm">
            {NAV.map((x) => (
              <Link
                key={x.href}
                href={x.href}
                className={"transition-colors hover:text-zinc-900 " + (x.href === CURRENT ? "text-zinc-900" : "text-zinc-700")}
              >
                {x.label}
              </Link>
            ))}
          </nav>
        </div>
      </header>

      <main className="mx-auto max-w-5xl px-6 py-12">
        <div className="max-w-2xl">
          <h1 className="text-4xl font-semibold tracking-tight">__PAGE_TITLE__</h1>
__TAGLINE_BLOCK__
        </div>

        <div className="mt-10 grid gap-6">
__SECTIONS__
        </div>
      </main>

      <footer className="border-t">
        <div className="mx-auto max-w-5xl px-6 py-8 text-xs text-zinc-500">
          Generated from plan hash __PLAN_HASH__
        </div>
      </footer>
    </div>
  );
}
"""

def canonical_hash(obj: dict) -> str:
    raw = json.dumps(obj, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode("utf-8")
    return hashlib.sha256(raw).hexdigest()[:12]

def tsconfig_json() -> dict:
    return {
        "compilerOptions": {
            "target": "ES2017",
            "lib": ["dom", "dom.iterable", "esnext"],
            "allowJs": True,
            "skipLibCheck": True,
            "strict": False,
            "noEmit": True,
            "esModuleInterop": True,
            "module": "esnext",
            "moduleResolution": "bundler",
            "resolveJsonModule": True,
            "isolatedModules": True,
            "jsx": "preserve",
            "incremental": True,
            "plugins": [{"name": "next"}],
        },
        "include": ["next-env.d.ts", "**/*.ts", "**/*.tsx", ".next/types/**/*.ts"],
        "exclude": ["node_modules"],
    }

def ensure_next_env(gen_dir: Path) -> None:
    p = gen_dir / "next-env.d.ts"
    if p.exists():
        return
    p.write_text(
        "/// <reference types=\"next\" />\n"
        "/// <reference types=\"next/image-types/global\" />\n\n"
        "// NOTE: This file is generated for Next.js TypeScript support.\n",
        encoding="utf-8",
    )

def render_sections(sections: list[str]) -> str:
    if not sections:
        sections = ["Overview"]
    blocks = []
    for s in sections:
        s = str(s)
        blocks.append(
            '          <section className="rounded-2xl border p-6 shadow-sm">\n'
            f'            <h2 className="text-base font-semibold">{s}</h2>\n'
            '            <p className="mt-2 text-sm text-zinc-600">\n'
            f'              Placeholder content for {s}. Enhance scaffold_web to render real components.\n'
            '            </p>\n'
            '          </section>'
        )
    return "\n".join(blocks)

def write_page(gen_dir: Path, app_title: str, tagline: str, nav_json: str, page_title: str, route: str, sections: list[str], plan_hash: str) -> None:
    tagline_block = ""
    if route == "/" and tagline.strip():
        tagline_block = f'          <p className="mt-3 text-zinc-600">{tagline}</p>'
    content = (
        TEMPLATE
        .replace("__APP_TITLE__", app_title.replace('"', '\\"'))
        .replace("__TAGLINE__", tagline.replace('"', '\\"'))
        .replace("__CURRENT__", route.replace('"', '\\"'))
        .replace("__NAV_JSON__", nav_json)
        .replace("__PAGE_TITLE__", page_title.replace('"', '\\"'))
        .replace("__TAGLINE_BLOCK__", tagline_block)
        .replace("__SECTIONS__", render_sections(sections))
        .replace("__PLAN_HASH__", plan_hash)
    )

    app_dir = gen_dir / "app"
    app_dir.mkdir(parents=True, exist_ok=True)
    if route == "/":
        out = app_dir / "page.tsx"
    else:
        seg = route.lstrip("/")
        out = app_dir / seg / "page.tsx"
        out.parent.mkdir(parents=True, exist_ok=True)

    out.write_text(content + "\n", encoding="utf-8")

    return out

def main() -> int:
    if not LATEST.exists():
        print("[apply_plan_web] Missing artifacts/runs/LATEST")
        return 2

    run_dir = Path(LATEST.read_text(encoding="utf-8").strip())
    plan_path = run_dir / "plan.web.json"
    if not plan_path.exists():
        print(f"[apply_plan_web] Missing {plan_path}")
        return 2

    plan = json.loads(plan_path.read_text(encoding="utf-8"))
    if plan.get("project_type") != "nextjs_site":
        print("[apply_plan_web] plan.project_type != nextjs_site")
        return 2

    name = plan["name"]
    app_title = plan.get("app_title", name)
    tagline = plan.get("tagline", "")

    pages = plan.get("pages", [])
    if not isinstance(pages, list) or not pages:
        print("[apply_plan_web] plan.pages empty")
        return 2

    plan_hash = canonical_hash(plan)
    gen_dir = GENERATED / f"{name}__{plan_hash}"
    if not gen_dir.exists():
        print(f"[apply_plan_web] gen_dir not found: {gen_dir}")
        return 2

    # lock tsconfig + next-env for determinism
    (gen_dir / "tsconfig.json").write_text(json.dumps(tsconfig_json(), ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    ensure_next_env(gen_dir)

    nav = [{"href": p.get("route", "/"), "label": p.get("title", "Page")} for p in pages]
    nav_json = json.dumps(nav, ensure_ascii=False, indent=2)

    applied_files = []

    for p in pages:
        route = p.get("route", "/")
        title = p.get("title", "Page")
        sections = p.get("sections") or []
        if not isinstance(sections, list):
            sections = []
        out_path = write_page(gen_dir, app_title, tagline, nav_json, title, route, [str(x) for x in sections], plan_hash)
        applied_files.append(str(out_path.relative_to(gen_dir)))

    (run_dir / "apply_web.log").write_text(
        "gen_dir=" + str(gen_dir) + "\n"
        + "files:\n- " + "\n- ".join(applied_files) + "\n",
        encoding="utf-8"
    )

    print(f"[apply_plan_web] OK gen_dir={gen_dir}")
    return 0

if __name__ == "__main__":
    raise SystemExit(main())
