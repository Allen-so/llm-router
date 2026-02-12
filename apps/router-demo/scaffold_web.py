#!/usr/bin/env python3
from __future__ import annotations

import hashlib
import json
import pathlib
import re
from typing import Any, Dict, List

ROOT = pathlib.Path(__file__).resolve().parents[2]
RUNS_DIR = ROOT / "artifacts" / "runs"
GENERATED_DIR = ROOT / "apps" / "generated"

SAFE_NAME_RE = re.compile(r"[^a-z0-9-]+")


def read_latest_run_dir() -> pathlib.Path:
    latest = RUNS_DIR / "LATEST"
    if latest.is_symlink():
        return latest.resolve()
    if latest.exists():
        s = latest.read_text(encoding="utf-8", errors="ignore").strip()
        if s and pathlib.Path(s).exists():
            return pathlib.Path(s).resolve()
    cands = sorted(RUNS_DIR.glob("run_*"), key=lambda x: x.stat().st_mtime, reverse=True)
    if not cands:
        raise SystemExit("No runs found under artifacts/runs")
    return cands[0].resolve()


def stable_hash(obj: Any) -> str:
    s = json.dumps(obj, sort_keys=True, separators=(",", ":"), ensure_ascii=False)
    return hashlib.sha256(s.encode("utf-8")).hexdigest()[:12]


def sanitize_name(name: str) -> str:
    n = (name or "").strip().lower().replace("_", "-").replace(" ", "-")
    n = SAFE_NAME_RE.sub("-", n)
    n = re.sub(r"-{2,}", "-", n).strip("-")
    return n or "site"


def write(path: pathlib.Path, content: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(content, encoding="utf-8")


def route_to_app_path(route: str) -> pathlib.Path:
    if route == "/":
        return pathlib.Path("app/page.tsx")
    segs = [s for s in route.strip("/").split("/") if s]
    return pathlib.Path("app", *segs, "page.tsx")


def main() -> int:
    run_dir = read_latest_run_dir()
    plan_path = run_dir / "plan.web.json"
    if not plan_path.exists():
        raise SystemExit(f"Missing {plan_path}. Put plan.web.json under the latest run dir.")

    plan: Dict[str, Any] = json.loads(plan_path.read_text(encoding="utf-8"))
    if plan.get("project_type") != "nextjs_site":
        raise SystemExit("plan.web.json project_type must be nextjs_site")

    name = sanitize_name(plan.get("name", "site"))
    h = stable_hash(plan)
    out_dir = GENERATED_DIR / f"{name}__{h}"
    out_dir.mkdir(parents=True, exist_ok=True)

    marker = out_dir / ".generated_from_run"
    if marker.exists():
        print(f"[ok] already generated: {out_dir}")
        return 0

    app_title = plan.get("app_title", name)
    tagline = plan.get("tagline", "")
    pages: List[Dict[str, Any]] = plan.get("pages", []) or [{"route": "/", "title": "Home", "sections": ["Hero"]}]
    nav = plan.get("nav") or [{"label": pg["title"], "route": pg["route"]} for pg in pages]

    write(out_dir / ".gitignore", "node_modules\n.next\nout\ndist\n.env*\n")

    write(out_dir / "RUN_INSTRUCTIONS.txt", f"""[run]
cd {out_dir}
npm install
npm run dev

[build]
npm run build
""")

    # Pinned stable stack: Next 14 + Tailwind 3 (avoid Tailwind v4/PostCSS changes)
    pkg = {
        "name": name,
        "private": True,
        "version": "0.1.0",
        "scripts": {"dev": "next dev", "build": "next build", "start": "next start", "lint": "next lint"},
        "dependencies": {"next": "14.2.0", "react": "18.2.0", "react-dom": "18.2.0"},
        "devDependencies": {
            "@types/node": "22.0.0",
            "@types/react": "18.2.66",
            "@types/react-dom": "18.2.22",
            "autoprefixer": "10.4.16",
            "eslint": "8.57.0",
            "eslint-config-next": "14.2.0",
            "postcss": "8.4.35",
            "tailwindcss": "3.4.1",
            "typescript": "5.5.4",
        },
    }
    write(out_dir / "package.json", json.dumps(pkg, indent=2))

    write(out_dir / "next.config.mjs", "/** @type {import('next').NextConfig} */\nconst nextConfig = {};\nexport default nextConfig;\n")
    write(out_dir / "postcss.config.js", "module.exports = { plugins: { tailwindcss: {}, autoprefixer: {} } };\n")

    write(out_dir / "tailwind.config.js", """/** @type {import('tailwindcss').Config} */
module.exports = {
  content: ["./app/**/*.{js,ts,jsx,tsx}", "./components/**/*.{js,ts,jsx,tsx}"],
  theme: { extend: {} },
  plugins: [],
};
""")

    write(
        out_dir / "tsconfig.json",
        json.dumps(
            {
                "compilerOptions": {
                    "target": "ES2022",
                    "lib": ["dom", "dom.iterable", "esnext"],
                    "skipLibCheck": True,
                    "strict": True,
                    "noEmit": True,
                    "esModuleInterop": True,
                    "module": "esnext",
                    "moduleResolution": "bundler",
                    "resolveJsonModule": True,
                    "isolatedModules": True,
                    "jsx": "preserve",
                    "incremental": True,
                    "types": ["node"],
                },
                "include": ["next-env.d.ts", "**/*.ts", "**/*.tsx"],
                "exclude": ["node_modules"],
            },
            indent=2,
        ),
    )

    write(out_dir / "next-env.d.ts", '/// <reference types="next" />\n/// <reference types="next/image-types/global" />\n')

    write(
        out_dir / "app/globals.css",
        "@tailwind base;\n@tailwind components;\n@tailwind utilities;\n\n:root { color-scheme: light; }\nbody { background: #fff; color: rgb(17 24 39); }\n",
    )

    write(
        out_dir / "components/SiteHeader.tsx",
        """import Link from "next/link";
type NavItem = { label: string; route: string };

export default function SiteHeader({ title, nav }: { title: string; nav: NavItem[] }) {
  return (
    <header className="sticky top-0 z-50 backdrop-blur border-b border-neutral-200/60 bg-white/70">
      <div className="mx-auto max-w-5xl px-4 py-3 flex items-center justify-between">
        <Link href="/" className="font-semibold tracking-tight">{title}</Link>
        <nav className="flex gap-4 text-sm text-neutral-600">
          {nav.map((it) => (
            <Link key={it.route} href={it.route} className="hover:text-neutral-900">{it.label}</Link>
          ))}
        </nav>
      </div>
    </header>
  );
}
""",
    )

    write(
        out_dir / "components/Footer.tsx",
        """export default function Footer() {
  return (
    <footer className="border-t border-neutral-200/60">
      <div className="mx-auto max-w-5xl px-4 py-8 text-sm text-neutral-500">
        Built with Next.js
      </div>
    </footer>
  );
}
""",
    )

    write(
        out_dir / "app/layout.tsx",
        f"""import "./globals.css";
import SiteHeader from "../components/SiteHeader";
import Footer from "../components/Footer";

export const metadata = {{
  title: "{app_title}",
  description: "{(tagline or app_title).replace('"', '\\"')}"
}};

const NAV = {json.dumps(nav, indent=2)};

export default function RootLayout({{ children }}: {{ children: React.ReactNode }}) {{
  return (
    <html lang="en">
      <body>
        <SiteHeader title="{app_title}" nav={{NAV}} />
        <main className="mx-auto max-w-5xl px-4 py-12">{{children}}</main>
        <Footer />
      </body>
    </html>
  );
}}
""",
    )

    for pg in pages:
        route = pg["route"]
        title = pg["title"]
        sections = pg.get("sections", [])
        sec_md = "\\n".join([f"- {s}" for s in sections]) if sections else "- Content"
        write(
            out_dir / route_to_app_path(route),
            f"""export default function Page() {{
  return (
    <div className="space-y-10">
      <section className="space-y-3">
        <h1 className="text-3xl font-semibold tracking-tight">{title}</h1>
        <p className="text-neutral-600">{tagline or "Apple-like minimal portfolio site."}</p>
      </section>

      <section className="rounded-2xl border border-neutral-200/70 p-6 shadow-sm">
        <h2 className="text-lg font-medium">Sections</h2>
        <pre className="mt-3 text-sm text-neutral-600 whitespace-pre-wrap">{sec_md}</pre>
      </section>
    </div>
  );
}}
""",
        )

    write(
        out_dir / ".generated_from_run",
        f"run_dir={run_dir}\nplan_hash={h}\nproject_type=nextjs_site\nplan_file={plan_path}\n",
    )

    print(f"[ok] generated web site at: {out_dir}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
