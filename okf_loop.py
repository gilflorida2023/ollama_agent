#!/usr/bin/env python3
"""
OKF Command Loop

Interactive CLI for OKF knowledge management with deep semantic processing
and hybrid search (tags + embeddings).

Usage:
    python3 okf_loop.py

Commands:
    ingest <url>        Clone repo, deep semantic processing, cleanup
    search <query>      Hybrid search: tags + semantic (via Qdrant)
    promote <id>        Move concept from new_bundles to trusted_bundles
    list [category]     List all concepts or filter by category
    browse <category>   Show detailed view of concepts
    corpora             List available corpora with concept counts
    remove <corpus>     Remove all concepts from a corpus
    cleanup [corpus]    Remove cloned repos (all or specific)
    help                Show available commands
    quit                Exit the loop
"""

import json
import os
import re
import subprocess
import sys
import hashlib
import asyncio
from datetime import datetime, timezone
from pathlib import Path
from urllib.parse import urlparse

import yaml
import readline  # enables up/down arrow command history editing


BASE_DIR = os.path.dirname(os.path.abspath(__file__))
KNOWLEDGE_DIR = os.path.join(BASE_DIR, "knowledge")
CORPORA_DIR = os.path.join(BASE_DIR, "corpora")
QDRANT_PATH = os.path.join(BASE_DIR, "qdrant_data")

OLLAMA_URL = "http://localhost:11434/api/chat"
EMBED_URL = "http://localhost:11434/api/embed"
EMBED_MODEL = "nomic-embed-text"


def get_md5(text):
    return hashlib.md5(text.encode("utf-8")).hexdigest()


def extract_repo_name(url):
    """Extract repo name from URL."""
    parsed = urlparse(url)
    path = parsed.path.rstrip('/')
    repo_name = path.split('/')[-1]
    if repo_name.endswith('.git'):
        repo_name = repo_name[:-4]
    return repo_name


# --- Embedding Engine ---

class EmbeddingEngine:
    """Qdrant + Ollama embedding engine for semantic search."""

    def __init__(self):
        try:
            from qdrant_client import QdrantClient
            from qdrant_client.http.models import Distance, VectorParams
            self.qdrant = QdrantClient(path=QDRANT_PATH)
            self.dimension = 768
            self._ensure_collection()
            self.available = True
        except Exception as e:
            print(f"  Warning: Qdrant not available: {e}")
            self.available = False

    def _ensure_collection(self):
        if not self.qdrant.collection_exists("okf_concepts"):
            from qdrant_client.http.models import Distance, VectorParams
            self.qdrant.create_collection(
                collection_name="okf_concepts",
                vectors_config=VectorParams(size=self.dimension, distance=Distance.COSINE),
            )

    def embed(self, texts):
        if not self.available:
            return []
        import requests
        resp = requests.post(EMBED_URL, json={"model": EMBED_MODEL, "input": texts}, timeout=60)
        resp.raise_for_status()
        data = resp.json()
        return [e for e in data.get("embeddings", [])]

    def upsert(self, concept_id, corpus, text, tags, status, file_path):
        if not self.available:
            return
        from qdrant_client.http.models import PointStruct
        embedding = self.embed([text])
        if not embedding:
            return
        self.qdrant.upsert(
            collection_name="okf_concepts",
            points=[PointStruct(
                id=get_md5(f"{concept_id}_{corpus}"),
                vector=embedding[0],
                payload={
                    "text": text[:2000],
                    "concept_id": concept_id,
                    "corpus": corpus,
                    "tags": tags,
                    "status": status,
                    "file_path": file_path,
                },
            )],
            wait=True,
        )

    def search(self, query, limit=5):
        if not self.available:
            return []
        embeddings = self.embed([query])
        if not embeddings:
            return []
        results = self.qdrant.query_points(
            collection_name="okf_concepts",
            query=embeddings[0],
            limit=limit,
        )
        return results.points


# --- Corpus Management ---

def clone_repo(url, local_dir):
    """Clone a repository."""
    if os.path.exists(local_dir):
        print(f"  Repository already exists at {local_dir}")
        return True
    
    print(f"Cloning {url}...")
    os.makedirs(os.path.dirname(local_dir), exist_ok=True)
    result = subprocess.run(
        ["git", "clone", "--depth", "1", url, local_dir],
        capture_output=True, text=True,
    )
    if result.returncode != 0:
        print(f"Error cloning: {result.stderr}")
        return False
    print(f"  Cloned to {local_dir}")
    return True


def detect_content_dir(repo_dir):
    """Auto-detect content directory in a cloned repository."""
    repo_path = Path(repo_dir)
    
    # Look for directories with markdown or XML files
    md_dirs = []
    xml_dirs = []
    
    for subdir in repo_path.rglob("*"):
        if subdir.is_dir():
            md_files = list(subdir.glob("*.md"))
            xml_files = list(subdir.glob("*.xml"))
            if md_files:
                md_dirs.append((subdir, len(md_files)))
            if xml_files:
                xml_dirs.append((subdir, len(xml_files)))
    
    # Prefer markdown directories
    if md_dirs:
        # Sort by file count, return directory with most files
        md_dirs.sort(key=lambda x: x[1], reverse=True)
        best_dir = md_dirs[0][0]
        print(f"  Auto-detected markdown content: {best_dir.relative_to(repo_path)}/")
        return str(best_dir), "markdown"
    
    # Fall back to XML directories
    if xml_dirs:
        xml_dirs.sort(key=lambda x: x[1], reverse=True)
        best_dir = xml_dirs[0][0]
        print(f"  Auto-detected XML content: {best_dir.relative_to(repo_path)}/")
        return str(best_dir), "xml"
    
    # Check root directory
    root_md = list(repo_path.glob("*.md"))
    root_xml = list(repo_path.glob("*.xml"))
    if root_md:
        print(f"  Using root directory (markdown)")
        return str(repo_path), "markdown"
    if root_xml:
        print(f"  Using root directory (XML)")
        return str(repo_path), "xml"
    
    return None, None


def convert_xml_to_markdown(xml_dir):
    """Convert Docbook XML files to Markdown using pandoc."""
    md_dir = xml_dir + "_converted"
    os.makedirs(md_dir, exist_ok=True)
    
    converted_count = 0
    for xml_file in Path(xml_dir).glob("*.xml"):
        md_file = os.path.join(md_dir, xml_file.stem + ".md")
        result = subprocess.run(
            ["pandoc", str(xml_file), "-f", "docbook", "-t", "markdown_github", "-o", md_file],
            capture_output=True, text=True,
        )
        if result.returncode == 0:
            converted_count += 1
        else:
            print(f"  Warning: Failed to convert {xml_file.name}: {result.stderr}")
    
    print(f"  Converted {converted_count} XML files to Markdown")
    return md_dir


def cleanup_repo(repo_dir):
    """Remove cloned repository directory."""
    if os.path.exists(repo_dir):
        import shutil
        shutil.rmtree(repo_dir)
        print(f"  Cleaned up: {repo_dir}")


def ingest_url(url):
    """Fetch a URL, convert HTML to Markdown, create a concept."""
    import html2text
    
    print(f"  Fetching {url}...")
    try:
        import urllib.request
        req = urllib.request.Request(url, headers={'User-Agent': 'Mozilla/5.0'})
        with urllib.request.urlopen(req, timeout=30) as response:
            html_content = response.read().decode('utf-8', errors='replace')
    except Exception as e:
        print(f"  Error fetching URL: {e}")
        return None
    
    # Convert HTML to Markdown
    print("  Converting HTML to Markdown...")
    h = html2text.HTML2Text()
    h.ignore_links = False
    h.ignore_images = False
    h.body_width = 0  # Don't wrap lines
    markdown_content = h.handle(html_content)
    
    # Extract title from URL or content
    from urllib.parse import urlparse
    parsed = urlparse(url)
    path_parts = [p for p in parsed.path.split('/') if p]
    slug = path_parts[-1] if path_parts else 'index'
    slug = re.sub(r'[^a-z0-9]+', '-', slug.lower()).strip('-')
    
    # Try to extract title from markdown (first # heading)
    title_match = re.search(r'^#\s+(.+)$', markdown_content, re.MULTILINE)
    if title_match:
        raw_title = title_match.group(1).strip()
    else:
        raw_title = slug.replace('-', ' ').title()
    
    title = f"How do I {raw_title}"
    concept_id = f"how-do-i-{slug}"
    
    # Escape quotes in title for YAML
    title_escaped = title.replace('"', '\\"')
    
    # Extract tags
    tags = ["web-content", parsed.netloc.replace('www.', '')]
    tag_patterns = {
        "python": r"\bpython\b",
        "javascript": r"\bjavascript\b|\bjs\b",
        "bash": r"\bbash\b|\bshell\b",
        "linux": r"\blinux\b",
        "ai": r"\bai\b|\bartificial.intelligence\b|\bmachine.learning\b|\bllm\b",
        "git": r"\bgit\b",
        "docker": r"\bdocker\b",
        "kubernetes": r"\bk8s\b|\bkubernetes\b",
    }
    for tag, pattern in tag_patterns.items():
        if re.search(pattern, markdown_content, re.IGNORECASE):
            tags.append(tag)
    
    tags_str = ", ".join(tags)
    
    # Build frontmatter
    frontmatter = f"""---
type: Reference
title: "{title_escaped}"
description: "{title_escaped}"
status: new
tags: [{tags_str}]
difficulty: intermediate
prerequisites: []
corpus: web-content
source_url: "{url}"
source_file: "{slug}.md"
generated:
  by: okf_loop/0.1
  at: {datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')}
---"""
    
    # Build full content
    full_content = f"{frontmatter}\n\n{markdown_content}"
    
    # Save to new_bundles/reference/
    ref_dir = os.path.join(KNOWLEDGE_DIR, "new_bundles", "reference")
    os.makedirs(ref_dir, exist_ok=True)
    md_file = os.path.join(ref_dir, f"{concept_id}.md")
    
    with open(md_file, 'w', encoding='utf-8') as f:
        f.write(full_content)
    
    print(f"  Created concept: {concept_id}")
    print(f"  Saved to: {md_file}")
    return {"id": concept_id, "path": md_file, "title": title}


async def crawl_and_ingest(start_url, corpus_name=None):
    """Crawl a website using crawl4ai and create OKF concepts from each page."""
    from crawl4ai import AsyncWebCrawler, CrawlerRunConfig, CacheMode
    from urllib.parse import urlparse, urljoin
    
    parsed = urlparse(start_url)
    if not corpus_name:
        corpus_name = parsed.netloc.replace('www.', '').replace('.', '-')
    
    print(f"  Crawling {start_url}...")
    print(f"  Corpus: {corpus_name}")
    
    concepts_created = []
    
    try:
        async with AsyncWebCrawler() as crawler:
            # Crawl the start page and follow internal links
            result = await crawler.arun(
                url=start_url,
                config=CrawlerRunConfig(
                    word_count_threshold=100,
                    exclude_external_links=True,
                    cache_mode=CacheMode.WRITE_ONLY,
                )
            )
            
            if not result.success:
                print(f"  Error crawling {start_url}: {result.error_message}")
                return []
            
            # Get all internal links found
            internal_links = set()
            if hasattr(result, 'links') and result.links:
                for link in result.links.get('internal', []):
                    href = link.get('href', '')
                    if href:
                        full_url = urljoin(start_url, href)
                        if full_url.startswith(start_url):
                            internal_links.add(full_url)
            
            print(f"  Found {len(internal_links)} internal links")
            
            # Process start page
            pages_to_process = [(start_url, result)]
            
            # Crawl internal links (limit to 50 pages to avoid overload)
            if internal_links:
                links_list = list(internal_links)[:50]
                print(f"  Crawling {len(links_list)} additional pages...")
                
                for link_url in links_list:
                    try:
                        link_result = await crawler.arun(
                            url=link_url,
                            config=CrawlerRunConfig(
                                word_count_threshold=100,
                                cache_mode=CacheMode.WRITE_ONLY,
                            )
                        )
                        if link_result.success:
                            pages_to_process.append((link_url, link_result))
                    except Exception as e:
                        print(f"  Warning: Failed to crawl {link_url}: {e}")
                        continue
            
            print(f"  Processing {len(pages_to_process)} pages...")
            
            # Create concepts from each page
            for page_url, page_result in pages_to_process:
                try:
                    # Get title from metadata or URL
                    title = page_result.metadata.get('title', '') if page_result.metadata else ''
                    if not title:
                        path_parts = [p for p in urlparse(page_url).path.split('/') if p]
                        title = path_parts[-1].replace('.en.html', '').replace('-', ' ').title() if path_parts else 'Index'
                    
                    # Clean up title
                    title = re.sub(r'\s+', ' ', title).strip()
                    if len(title) > 100:
                        title = title[:100] + '...'
                    
                    # Get markdown content
                    markdown_content = page_result.markdown if page_result.markdown else ''
                    if len(markdown_content.strip()) < 100:
                        continue
                    
                    # Strip table of contents (lines with [Section X.Y.Z](URL) pattern)
                    lines = markdown_content.split('\n')
                    toc_end = 0
                    for i, line in enumerate(lines):
                        # Stop stripping when we hit actual content (headings with ### or code blocks)
                        if re.match(r'^#{2,3}\s+\d+\.\d+', line) or line.startswith('```'):
                            toc_end = i
                            break
                        # Skip TOC lines (links to sections)
                        if re.match(r'^\[[\d\.]+.*\]\(.*en\.html', line):
                            continue
                        # Skip empty lines in TOC
                        if not line.strip() and i < 350:
                            continue
                        # If we've gone past typical TOC length, stop
                        if i > 350:
                            toc_end = i
                            break
                    
                    if toc_end > 0:
                        markdown_content = '\n'.join(lines[toc_end:])
                    
                    # Create concept ID from URL
                    path_parts = [p for p in urlparse(page_url).path.split('/') if p]
                    slug = path_parts[-1].replace('.en.html', '') if path_parts else 'index'
                    slug = re.sub(r'[^a-z0-9]+', '-', slug.lower()).strip('-')
                    concept_id = f"how-do-i-{slug}"
                    
                    # Escape quotes
                    title_escaped = title.replace('"', '\\"')
                    
                    # Extract tags from content
                    tags = [corpus_name, "debian", "linux"]
                    tag_patterns = {
                        "bash": r"\bbash\b|\bshell\b",
                        "networking": r"\bnetwork\b|\bfirewall\b|\bip\b",
                        "security": r"\bsecurity\b|\bauth\b|\bpassword\b",
                        "package-management": r"\bapt\b|\bdpkg\b|\bpackage\b",
                        "systemd": r"\bsystemd\b|\bsystemctl\b",
                        "ssh": r"\bssh\b",
                        "storage": r"\bdisk\b|\bpartition\b|\bfilesystem\b",
                        "vim": r"\bvim\b",
                        "git": r"\bgit\b",
                    }
                    for tag, pattern in tag_patterns.items():
                        if re.search(pattern, markdown_content, re.IGNORECASE):
                            tags.append(tag)
                    
                    tags_str = ", ".join(tags)
                    
                    # Build frontmatter
                    frontmatter = f"""---
type: Reference
title: "How do I {title_escaped}"
description: "{title_escaped}"
status: new
tags: [{tags_str}]
difficulty: intermediate
prerequisites: []
corpus: {corpus_name}
source_url: "{page_url}"
source_file: "{slug}.md"
generated:
  by: okf_loop/0.1
  at: {datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')}
---"""
                    
                    # Build full content
                    full_content = f"{frontmatter}\n\n{markdown_content}"
                    
                    # Save to new_bundles/reference/
                    ref_dir = os.path.join(KNOWLEDGE_DIR, "new_bundles", "reference")
                    os.makedirs(ref_dir, exist_ok=True)
                    md_file = os.path.join(ref_dir, f"{concept_id}.md")
                    
                    # Skip if already exists
                    if os.path.exists(md_file):
                        concepts_created.append({"id": concept_id, "path": md_file, "title": title, "existing": True})
                        continue
                    
                    with open(md_file, 'w', encoding='utf-8') as f:
                        f.write(full_content)
                    
                    concepts_created.append({"id": concept_id, "path": md_file, "title": title, "existing": False})
                    print(f"    Created: {concept_id}")
                    
                except Exception as e:
                    print(f"  Warning: Failed to process page: {e}")
                    continue
    
    except Exception as e:
        print(f"  Error during crawl: {e}")
        return []
    
    return concepts_created


def convert_html_tables_to_markdown(content):
    """Convert HTML tables in markdown content to markdown tables and clean other HTML."""
    from bs4 import BeautifulSoup
    
    def html_table_to_markdown(html):
        soup = BeautifulSoup(html, 'html.parser')
        table = soup.find('table')
        if not table:
            return html
        
        rows = []
        for tr in table.find_all('tr'):
            cells = []
            for td in tr.find_all(['td', 'th']):
                cells.append(td.get_text(strip=True))
            if cells:
                rows.append(cells)
        
        if not rows:
            return html
        
        # Build markdown table
        max_cols = max(len(r) for r in rows)
        lines = []
        
        # Header row
        header = rows[0] if rows else []
        header.extend([''] * (max_cols - len(header)))
        lines.append('| ' + ' | '.join(header) + ' |')
        lines.append('|' + '|'.join(['---'] * max_cols) + '|')
        
        # Data rows
        for row in rows[1:]:
            row.extend([''] * (max_cols - len(row)))
            lines.append('| ' + ' | '.join(row) + ' |')
        
        return '\n'.join(lines)
    
    # Find and replace HTML tables
    import re
    table_pattern = re.compile(r'<table[^>]*>.*?</table>', re.DOTALL | re.IGNORECASE)
    
    def replace_table(match):
        return html_table_to_markdown(match.group(0))
    
    content = table_pattern.sub(replace_table, content)
    
    # Remove other HTML tags (spans, divs, etc.) but keep content
    html_tag_pattern = re.compile(r'<[^>]+>')
    content = html_tag_pattern.sub('', content)
    
    # Clean up extra whitespace
    content = re.sub(r'\n{3,}', '\n\n', content)
    
    return content


# --- Deep Semantic Processing ---

def extract_tags(content, corpus_name):
    """Extract relevant tags from content."""
    tags = [corpus_name]
    tag_patterns = {
        "python": r"\bpython\b",
        "java": r"\bjava\b",
        "bash": r"\bbash\b|\bshell\b",
        "linux": r"\blinux\b",
        "ssh": r"\bssh\b",
        "dns": r"\bdns\b",
        "dhcp": r"\bdhcp\b",
        "apache": r"\bapache\b",
        "networking": r"\bnetwork\b|\bfirewall\b",
        "security": r"\bsecurity\b|\bencrypt\b|\bauth\b",
        "data-structure": r"\barray\b|\blinked.list\b|\btree\b|\bstack\b|\bqueue\b",
        "algorithm": r"\bsort\b|\bsearch\b|\btraverse\b",
        "recursion": r"\brecurs\w+\b",
        "complexity": r"\btime.complexity\b|\bspace.complexity\b|\bO\(n\)",
    }
    for tag, pattern in tag_patterns.items():
        if re.search(pattern, content, re.IGNORECASE):
            tags.append(tag)
    return tags


def extract_difficulty(content):
    """Determine difficulty level from content."""
    advanced_indicators = ["advanced", "complex", "optimization", "dynamic programming", "graph algorithm"]
    intermediate_indicators = ["intermediate", "configuration", "setup", "server", "networking"]

    content_lower = content.lower()
    if any(w in content_lower for w in advanced_indicators):
        return "advanced"
    elif any(w in content_lower for w in intermediate_indicators):
        return "intermediate"
    return "beginner"


def extract_prerequisites(content, all_concepts):
    """Extract prerequisites based on content analysis."""
    prereqs = []
    content_lower = content.lower()

    prereq_keywords = {
        "basic-commands": ["command line", "terminal", "shell"],
        "user-management": ["user", "group", "permission"],
        "file-system": ["file", "directory", "folder"],
        "networking-basics": ["network", "ip address", "port"],
        "data-structures": ["array", "linked list", "stack", "queue"],
        "recursion": ["recursive", "recursion"],
    }

    for prereq, keywords in prereq_keywords.items():
        if any(kw in content_lower for kw in keywords):
            prereqs.append(prereq)

    return prereqs[:3]


def generate_how_do_i_title(raw_title):
    """Convert raw title to 'How do I' format."""
    title = raw_title.strip()
    if title.lower().startswith("how do i"):
        return title
    if title.lower().startswith("how to"):
        return "How do I " + title[7:]
    return "How do I " + title


def process_corpus(content_dir, corpus_name, source_url, content_type="markdown"):
    """Process a corpus with deep semantic processing."""
    ref_dir = os.path.join(KNOWLEDGE_DIR, "new_bundles", "reference")
    os.makedirs(ref_dir, exist_ok=True)

    # If XML, convert to markdown first
    if content_type == "xml":
        print("  Converting XML to Markdown...")
        content_dir = convert_xml_to_markdown(content_dir)

    md_files = list(Path(content_dir).rglob("*.md"))
    if not md_files:
        print(f"  No markdown files found in {content_dir}")
        return []

    print(f"  Processing {len(md_files)} files...")

    all_concepts = []
    concepts_created = []

    for md_file in md_files:
        try:
            content = md_file.read_text(encoding="utf-8", errors="replace")
            
            # Convert HTML tables to markdown tables
            content = convert_html_tables_to_markdown(content)
            
            if len(content.strip()) < 100:
                continue

            # Level 1: Extract title and basic info
            title_match = re.search(r'^#\s+(.+)$', content, re.MULTILINE)
            raw_title = title_match.group(1).strip() if title_match else md_file.stem.replace('-', ' ').replace('_', ' ').title()
            title = generate_how_do_i_title(raw_title)

            concept_id = re.sub(r'[^a-z0-9]+', '-', title.lower()).strip('-')

            # Level 2: Enrich tags and metadata
            tags = extract_tags(content, corpus_name)
            difficulty = extract_difficulty(content)

            # Level 3: Extract prerequisites and relationships
            prerequisites = extract_prerequisites(content, all_concepts)

            # Build frontmatter
            tags_str = ", ".join(tags)
            prereqs_str = "\n".join([f"  - {p}" for p in prerequisites]) if prerequisites else "  - []"

            # Extract first paragraph as description
            desc_match = re.search(r'^#\s+.+\n\n(.+?)(?=\n\n|\n#)', content, re.MULTILINE | re.DOTALL)
            description = desc_match.group(1).strip()[:200] if desc_match else title

            # Calculate relative source file path
            try:
                source_file = str(md_file.relative_to(content_dir))
            except ValueError:
                source_file = md_file.name

            concept = f"""---
type: Reference
title: "{title}"
description: "{description}"
status: new
tags: [{tags_str}]
difficulty: {difficulty}
prerequisites:
{prereqs_str}
corpus: {corpus_name}
source_url: "{source_url}"
source_file: {source_file}
generated:
  by: okf_loop/0.1
  at: {datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')}
---

{content}
"""
            concept_path = os.path.join(ref_dir, f"{concept_id}.md")
            with open(concept_path, "w") as f:
                f.write(concept)

            all_concepts.append(concept_id)
            concepts_created.append({
                "id": concept_id,
                "title": title,
                "path": concept_path,
                "tags": tags,
            })

        except Exception as e:
            print(f"  Warning: {md_file}: {e}")

    return concepts_created


def llm_enrich_concept(concept_path, model="qwen2.5-coder:7b"):
    """Use Ollama to enrich a concept with LLM analysis."""
    try:
        import requests

        with open(concept_path) as f:
            content = f.read()

        prompt = f"""Analyze this OKF concept and suggest improvements.

Current content:
{content[:3000]}

Return a JSON object with these fields (if improvements needed):
- title: Improved "How do I..." format
- description: Better 1-2 sentence description
- tags: Additional relevant tags (array)
- difficulty: beginner/intermediate/advanced
- prerequisites: Related concepts (array)
- agent_instructions: What an agent should know (string)
- verification_steps: How to verify success (array of strings)

Return ONLY the JSON object, no other text."""

        payload = {
            "model": model,
            "messages": [{"role": "user", "content": prompt}],
            "stream": False,
            "temperature": 0,
        }

        resp = requests.post(OLLAMA_URL, json=payload, timeout=60)
        resp.raise_for_status()
        response_text = resp.json().get("message", {}).get("content", "")

        json_match = re.search(r'\{[^{}]*\}', response_text, re.DOTALL)
        if json_match:
            return json.loads(json_match.group())

    except Exception as e:
        print(f"  LLM enrichment failed: {e}")

    return None


# --- Search ---

def hybrid_search(query, limit=5):
    """Search OKF concepts using both tags and semantic search."""
    results = []

    # Tag-based search
    tag_results = search_by_tags(query)
    for r in tag_results:
        r["match_type"] = "tag"
        r["score"] = 1.0
        results.append(r)

    # Semantic search via embeddings
    engine = EmbeddingEngine()
    if engine.available:
        semantic_results = engine.search(query, limit=limit)
        for point in semantic_results:
            payload = point.payload
            if payload.get("file_path") not in [r.get("file_path") for r in results]:
                results.append({
                    "concept_id": payload.get("concept_id"),
                    "title": payload.get("concept_id", "").replace('-', ' ').title(),
                    "tags": payload.get("tags", []),
                    "file_path": payload.get("file_path"),
                    "match_type": "semantic",
                    "score": point.score,
                })

    results.sort(key=lambda x: x.get("score", 0), reverse=True)
    return results[:limit]


def search_by_tags(query):
    """Search concepts by tag matching."""
    results = []
    ref_dirs = [
        os.path.join(KNOWLEDGE_DIR, "new_bundles", "reference"),
        os.path.join(KNOWLEDGE_DIR, "trusted_bundles", "reference"),
    ]

    query_words = set(query.lower().split())

    for ref_dir in ref_dirs:
        if not os.path.exists(ref_dir):
            continue
        for md_file in Path(ref_dir).glob("*.md"):
            try:
                content = md_file.read_text(encoding="utf-8", errors="replace")
                fm_match = re.search(r'^---\n(.+?)\n---', content, re.DOTALL)
                if not fm_match:
                    continue
                frontmatter = yaml.safe_load(fm_match.group(1))
                tags = set(frontmatter.get("tags", []))
                title = frontmatter.get("title", "")

                tag_overlap = len(query_words.intersection(set(t.lower() for t in tags)))
                title_match = any(w in title.lower() for w in query_words)

                if tag_overlap > 0 or title_match:
                    results.append({
                        "concept_id": md_file.stem,
                        "title": title,
                        "tags": list(tags),
                        "file_path": str(md_file),
                        "match_type": "tag",
                        "score": tag_overlap / max(len(query_words), 1),
                    })
            except Exception:
                continue

    return results


def view_concept(concept_id):
    """View the full content of a concept using a pager."""
    ref_dirs = [
        os.path.join(KNOWLEDGE_DIR, "trusted_bundles", "reference"),
        os.path.join(KNOWLEDGE_DIR, "new_bundles", "reference"),
    ]

    for ref_dir in ref_dirs:
        if not os.path.exists(ref_dir):
            continue
        md_file = os.path.join(ref_dir, f"{concept_id}.md")
        if os.path.exists(md_file):
            content = open(md_file).read()
            header = f"\n{'='*60}\nFile: {md_file}\n{'='*60}\n\n"
            full_text = header + content
            
            # Use less or more pager
            pager = None
            for p in ['less', 'more']:
                if os.path.exists(f'/usr/bin/{p}') or os.path.exists(f'/bin/{p}'):
                    pager = p
                    break
            
            if pager:
                process = subprocess.Popen([pager], stdin=subprocess.PIPE)
                process.communicate(input=full_text.encode())
            else:
                print(full_text)
            return True

    print(f"Concept not found: {concept_id}")
    return False


# --- Index Generation ---

def generate_indexes():
    """Generate OKF index files for reference categories."""
    for bundle_type in ["new_bundles", "trusted_bundles"]:
        ref_dir = os.path.join(KNOWLEDGE_DIR, bundle_type, "reference")
        if not os.path.exists(ref_dir):
            continue

        concepts = []
        for md_file in Path(ref_dir).glob("*.md"):
            try:
                content = md_file.read_text(encoding="utf-8", errors="replace")
                fm_match = re.search(r'^---\n(.+?)\n---', content, re.DOTALL)
                if fm_match:
                    frontmatter = yaml.safe_load(fm_match.group(1))
                    concepts.append({
                        "id": md_file.stem,
                        "title": frontmatter.get("title", md_file.stem),
                        "tags": frontmatter.get("tags", []),
                        "status": frontmatter.get("status", "new"),
                        "corpus": frontmatter.get("corpus", ""),
                    })
            except Exception:
                continue

        index_md = f"# Reference Concepts ({bundle_type})\n\n"
        for c in concepts:
            tags_str = ", ".join(c.get("tags", []))
            index_md += f"- [{c['title']}]({c['id']}.md) — {tags_str}\n"

        with open(os.path.join(ref_dir, "index.md"), "w") as f:
            f.write(index_md)

        with open(os.path.join(ref_dir, "index.json"), "w") as f:
            json.dump({"concepts": concepts}, f, indent=2)


def generate_master_index():
    """Generate master index.md for all OKF content."""
    entries = []

    for bundle_type in ["new_bundles", "trusted_bundles"]:
        ref_dir = os.path.join(KNOWLEDGE_DIR, bundle_type, "reference")
        if os.path.exists(ref_dir):
            count = len(list(Path(ref_dir).glob("*.md")))
            if count > 0:
                entries.append(f"- [{bundle_type}/reference/]({count} concepts)")

    index_content = "# OKF Knowledge Bundle\n\n## Categories\n\n"
    if entries:
        index_content += "\n".join(entries) + "\n"
    else:
        index_content += "No reference concepts yet.\n"

    with open(os.path.join(KNOWLEDGE_DIR, "index.md"), "w") as f:
        f.write(index_content)


# --- Promote ---

def promote_concept(concept_id):
    """Promote a concept from new_bundles to trusted_bundles."""
    src = os.path.join(KNOWLEDGE_DIR, "new_bundles", "reference", f"{concept_id}.md")
    dst_dir = os.path.join(KNOWLEDGE_DIR, "trusted_bundles", "reference")
    dst = os.path.join(dst_dir, f"{concept_id}.md")

    if not os.path.exists(src):
        print(f"Error: Concept not found: {concept_id}")
        return False

    os.makedirs(dst_dir, exist_ok=True)

    content = open(src).read()
    content = re.sub(r'status: new', 'status: trusted', content)

    with open(dst, "w") as f:
        f.write(content)

    os.remove(src)
    print(f"Promoted: {concept_id}")
    generate_indexes()
    return True


def remove_corpus(corpus_name):
    """Remove all concepts from a specific corpus."""
    removed = 0
    
    for bundle_type in ["new_bundles", "trusted_bundles"]:
        ref_dir = os.path.join(KNOWLEDGE_DIR, bundle_type, "reference")
        if not os.path.exists(ref_dir):
            continue
        
        for md_file in Path(ref_dir).glob("*.md"):
            try:
                content = md_file.read_text(encoding="utf-8", errors="replace")
                fm_match = re.search(r'^---\n(.+?)\n---', content, re.DOTALL)
                if fm_match:
                    frontmatter = yaml.safe_load(fm_match.group(1))
                    if frontmatter.get("corpus") == corpus_name:
                        md_file.unlink()
                        removed += 1
            except Exception:
                continue
    
    if removed > 0:
        print(f"Removed {removed} concepts from '{corpus_name}'")
        generate_indexes()
    else:
        print(f"No concepts found for corpus '{corpus_name}'")
    
    return removed


# --- List / Browse ---

def list_concepts(category=None, corpus=None):
    """List all concepts, optionally filtered by category and/or corpus."""
    concepts = []

    for bundle_type in ["new_bundles", "trusted_bundles"]:
        ref_dir = os.path.join(KNOWLEDGE_DIR, bundle_type, "reference")
        if not os.path.exists(ref_dir):
            continue
        for md_file in Path(ref_dir).glob("*.md"):
            try:
                content = md_file.read_text(encoding="utf-8", errors="replace")
                fm_match = re.search(r'^---\n(.+?)\n---', content, re.DOTALL)
                if fm_match:
                    frontmatter = yaml.safe_load(fm_match.group(1))
                    status = frontmatter.get("status", "new")
                    concept_corpus = frontmatter.get("corpus", "")
                    
                    if category and status != category:
                        continue
                    if corpus and concept_corpus != corpus:
                        continue
                    
                    concepts.append({
                        "id": md_file.stem,
                        "title": frontmatter.get("title", md_file.stem),
                        "tags": frontmatter.get("tags", []),
                        "status": status,
                        "bundle": bundle_type,
                        "corpus": concept_corpus,
                    })
            except Exception:
                continue

    if not concepts:
        print("No concepts found.")
        return

    print(f"\nFound {len(concepts)} concepts:\n")
    for c in concepts:
        tags_str = ", ".join(c["tags"][:3])
        print(f"  {c['id']} [{c['status']}] — {c['title'][:50]}  ({tags_str})")


def list_corpora():
    """List all available corpora with concept counts."""
    corpora = {}
    
    for bundle_type in ["new_bundles", "trusted_bundles"]:
        ref_dir = os.path.join(KNOWLEDGE_DIR, bundle_type, "reference")
        if not os.path.exists(ref_dir):
            continue
        for md_file in Path(ref_dir).glob("*.md"):
            try:
                content = md_file.read_text(encoding="utf-8", errors="replace")
                fm_match = re.search(r'^---\n(.+?)\n---', content, re.DOTALL)
                if fm_match:
                    frontmatter = yaml.safe_load(fm_match.group(1))
                    corpus = frontmatter.get("corpus", "unknown")
                    if corpus not in corpora:
                        corpora[corpus] = {"count": 0, "url": frontmatter.get("source_url", "")}
                    corpora[corpus]["count"] += 1
            except Exception:
                continue

    if not corpora:
        print("No corpora found.")
        return

    print("\nAvailable corpora:\n")
    for corpus, info in sorted(corpora.items()):
        print(f"  {corpus} — {info['count']} concepts")
        if info['url']:
            print(f"    Source: {info['url']}")
    print()


def browse_category(category):
    """Browse detailed view of concepts in a category."""
    found = False
    for bundle_type in ["new_bundles", "trusted_bundles"]:
        ref_dir = os.path.join(KNOWLEDGE_DIR, bundle_type, "reference")
        if not os.path.exists(ref_dir):
            continue
        for md_file in Path(ref_dir).glob("*.md"):
            try:
                content = md_file.read_text(encoding="utf-8", errors="replace")
                fm_match = re.search(r'^---\n(.+?)\n---', content, re.DOTALL)
                if fm_match:
                    frontmatter = yaml.safe_load(fm_match.group(1))
                    tags = frontmatter.get("tags", [])
                    if category in tags or category == md_file.stem:
                        print(f"\n{'='*60}")
                        print(f"File: {md_file.name}")
                        print(f"Title: {frontmatter.get('title', 'N/A')}")
                        print(f"Status: {frontmatter.get('status', 'N/A')}")
                        print(f"Tags: {', '.join(tags)}")
                        print(f"Source: {frontmatter.get('source_url', 'N/A')}")
                        print(f"{'='*60}")
                        body_start = content.find("---", 3) + 3
                        print(content[body_start:body_start+500])
                        print("...\n")
                        found = True
            except Exception:
                continue

    if not found:
        print(f"No concepts found for '{category}'")


# --- Main Loop ---

def print_help():
    """Print available commands."""
    print("""
OKF Command Loop — Available Commands:

  ingest <url>         Clone repo, deep semantic processing, cleanup
  ingest_url <url>     Fetch URL, convert HTML to Markdown, create concept
  ingest_crawl <url>   Crawl website, convert pages to Markdown, create concepts
  search <query>       Hybrid search: tags + semantic similarity
  view <concept>       View full content of a concept
  promote <concept>    Move concept from new_bundles to trusted_bundles
  remove <corpus>      Remove all concepts from a corpus
  corpora              List available corpora with concept counts
  list [filter]        List concepts (filters: new, trusted, --corpus <name>)
  browse <category>    Browse detailed view of concepts
  cleanup [corpus]     Remove cloned repos (all or specific)
  help                 Show this help message
  quit                 Exit the loop
""")


def execute_command(cmd, args):
    """Execute a single OKF command. Returns 'quit' to signal loop exit, None otherwise."""
    if cmd == "quit" or cmd == "exit":
        print("Goodbye.")
        return "quit"

    elif cmd == "help":
        print_help()

    elif cmd == "ingest":
        if not args:
            print("Usage: ingest <url>")
            print("Example: ingest https://github.com/HoGentTIN/linux-training-hogent.git")
            return None

        url = args.strip()
        repo_name = extract_repo_name(url)
        local_dir = os.path.join(CORPORA_DIR, repo_name)

        # Clone the repository
        if not clone_repo(url, local_dir):
            return None

        # Auto-detect content directory
        print(f"\nAuto-detecting content in {repo_name}...")
        content_dir, content_type = detect_content_dir(local_dir)
        
        if not content_dir:
            print(f"Error: No content found in {repo_name}")
            cleanup_repo(local_dir)
            return None

        # Process the corpus
        print(f"\nDeep semantic processing for {repo_name}...")
        concepts = process_corpus(content_dir, repo_name, url, content_type)
        print(f"  Created {len(concepts)} concepts")

        # LLM enrichment (optional)
        print("  Level 4: LLM enrichment (if Ollama available)...")
        model = os.environ.get("OKF_LLM_MODEL", "qwen2.5-coder:7b")
        enriched = 0
        for c in concepts[:5]:
            enrichment = llm_enrich_concept(c["path"], model)
            if enrichment:
                enriched += 1
        print(f"  Enriched {enriched} concepts with LLM")

        # Embeddings
        print("  Generating embeddings...")
        engine = EmbeddingEngine()
        if engine.available:
            for c in concepts:
                try:
                    content = open(c["path"]).read()
                    body_start = content.find("---", 3) + 3
                    text = content[body_start:2000]
                    engine.upsert(c["id"], repo_name, text, c["tags"], "new", c["path"])
                except Exception:
                    pass
            print(f"  Stored {len(concepts)} embeddings in Qdrant")
        else:
            print("  Skipped (Qdrant not available)")

        # Generate indexes
        print("  Generating indexes...")
        generate_indexes()
        generate_master_index()

        # Cleanup converted XML directory if it exists
        converted_dir = content_dir + "_converted"
        if os.path.exists(converted_dir):
            cleanup_repo(converted_dir)

        # Cleanup cloned repository
        print(f"\nIngestion complete. Cleaning up cloned repository...")
        cleanup_repo(local_dir)

        print(f"\nDone! Ingested {len(concepts)} concepts from {repo_name}")
        print(f"Location: knowledge/new_bundles/reference/")

    elif cmd == "ingest_url":
        if not args:
            print("Usage: ingest_url <url>")
            print("Example: ingest_url https://ghuntley.com/ralph/")
            return None

        url = args.strip()
        print(f"\nIngesting URL content...")
        result = ingest_url(url)
        
        if result:
            # Generate indexes
            print("  Generating indexes...")
            generate_indexes()
            generate_master_index()
            
            print(f"\nDone! Ingested content from {url}")
            print(f"Concept: {result['id']}")
            print(f"Location: knowledge/new_bundles/reference/")
        else:
            print(f"\nFailed to ingest content from {url}")

    elif cmd == "ingest_crawl":
        if not args:
            print("Usage: ingest_crawl <url> [corpus_name]")
            print("Example: ingest_crawl https://www.debian.org/doc/manuals/debian-reference/")
            return None

        crawl_parts = args.strip().split(maxsplit=1)
        crawl_url = crawl_parts[0]
        corpus_name = crawl_parts[1] if len(crawl_parts) > 1 else None
        
        print(f"\nCrawling website...")
        concepts = asyncio.run(crawl_and_ingest(crawl_url, corpus_name))
        
        if concepts:
            # Generate indexes
            print("  Generating indexes...")
            generate_indexes()
            generate_master_index()
            
            new_count = sum(1 for c in concepts if not c.get("existing", False))
            existing_count = sum(1 for c in concepts if c.get("existing", False))
            
            print(f"\nDone! Crawled {len(concepts)} pages")
            if new_count > 0:
                print(f"  New: {new_count}")
            if existing_count > 0:
                print(f"  Existing: {existing_count}")
            print(f"Location: knowledge/new_bundles/reference/")
        else:
            print(f"\nFailed to crawl content from {crawl_url}")

    elif cmd == "search":
        if not args:
            print("Usage: search <query>")
            return None

        print(f"\nSearching for: {args}")
        results = hybrid_search(args)

        if not results:
            print("No results found.")
        else:
            print(f"\nFound {len(results)} results:\n")
            for i, r in enumerate(results, 1):
                match_type = r.get("match_type", "unknown")
                score = r.get("score", 0)
                tags_str = ", ".join(r.get("tags", [])[:3])
                print(f"  {i}. {r['concept_id']} [{match_type}: {score:.2f}]")
                print(f"     Tags: {tags_str}")
                print(f"     Path: {r.get('file_path', 'N/A')}")
                print()

    elif cmd == "promote":
        if not args:
            print("Usage: promote <concept_id>")
            return None
        promote_concept(args.strip())

    elif cmd == "list":
        category = None
        corpus = None
        if args:
            list_parts = args.split()
            i = 0
            while i < len(list_parts):
                if list_parts[i] == "--corpus" and i + 1 < len(list_parts):
                    corpus = list_parts[i + 1]
                    i += 2
                else:
                    category = list_parts[i]
                    i += 1
        list_concepts(category=category, corpus=corpus)

    elif cmd == "corpora":
        list_corpora()

    elif cmd == "remove":
        if not args:
            print("Usage: remove <corpus_name>")
            return None
        corpus_name = args.strip()
        confirm = input(f"Remove all concepts from '{corpus_name}'? [y/N] ").strip().lower()
        if confirm == "y":
            remove_corpus(corpus_name)

    elif cmd == "browse":
        if not args:
            print("Usage: browse <category_or_concept>")
            return None
        browse_category(args.strip())

    elif cmd == "view":
        if not args:
            print("Usage: view <concept_id>")
            return None
        view_concept(args.strip())

    elif cmd == "cleanup":
        if args:
            cleanup_repo(os.path.join(CORPORA_DIR, args.strip()))
        else:
            confirm = input("Remove all cloned corpora? [y/N] ").strip().lower()
            if confirm == "y":
                if os.path.exists(CORPORA_DIR):
                    import shutil
                    shutil.rmtree(CORPORA_DIR)
                    print(f"Removed all corpora: {CORPORA_DIR}")
        generate_indexes()

    else:
        print(f"Unknown command: {cmd}. Type 'help' for available commands.")

    return None


def main():
    print("=" * 60)
    print("OKF Command Loop v1.0")
    print("Type 'help' for available commands.")
    print("Type 'quit' to exit.")
    print("Tip: use ';' to chain commands on one line, e.g: search foo; list reference")
    print("=" * 60)

    # Ensure knowledge directories exist
    os.makedirs(os.path.join(KNOWLEDGE_DIR, "new_bundles", "reference"), exist_ok=True)
    os.makedirs(os.path.join(KNOWLEDGE_DIR, "trusted_bundles", "reference"), exist_ok=True)
    os.makedirs(CORPORA_DIR, exist_ok=True)

    while True:
        try:
            user_input = input("\nokf> ").strip()
        except (EOFError, KeyboardInterrupt):
            print("\nExiting...")
            break

        if not user_input:
            continue

        # Split on semicolons for chained commands
        commands = user_input.split(";")

        for cmd_str in commands:
            cmd_str = cmd_str.strip()
            if not cmd_str:
                continue

            parts = cmd_str.split(maxsplit=1)
            cmd = parts[0].lower()
            args = parts[1] if len(parts) > 1 else ""

            result = execute_command(cmd, args)
            if result == "quit":
                return


if __name__ == "__main__":
    main()
