#!/usr/bin/env node
// Seed the 5 category README discussions on vade-app/vade-core and pin them.
//
// Idempotent: skips creation if a discussion with the same title already
// exists in the target category. Pin attempt is best-effort — if the token
// lacks the required scope, the script logs and continues.
//
// Usage:
//   GITHUB_TOKEN=<pat> node scripts/seed-discussions/seed.mjs
//   GITHUB_TOKEN=<pat> node scripts/seed-discussions/seed.mjs --dry-run
//
// Requires: PAT with read+write Discussions. Pinning requires repo admin.

import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));

const OWNER = 'vade-app';
const REPO = 'vade-core';

const POSTS = [
  { category: 'Announcements',  file: 'announcements.md',  title: 'README: how Announcements works' },
  { category: 'Coordination',   file: 'coordination.md',   title: 'README: how Coordination works' },
  { category: 'RFCs',           file: 'rfcs.md',           title: 'README: how RFCs work + RFC template' },
  { category: 'Retrospectives', file: 'retrospectives.md', title: 'README: how Retrospectives work' },
  { category: 'Q&A',            file: 'qa.md',             title: 'README: how Q&A works' },
];

const DRY_RUN = process.argv.includes('--dry-run');
const TOKEN = process.env.GITHUB_TOKEN || process.env.GH_TOKEN;
if (!TOKEN) {
  console.error('Error: set GITHUB_TOKEN (or GH_TOKEN) env var.');
  process.exit(1);
}

async function gql(query, variables = {}) {
  const res = await fetch('https://api.github.com/graphql', {
    method: 'POST',
    headers: {
      Authorization: `bearer ${TOKEN}`,
      'Content-Type': 'application/json',
      'User-Agent': 'vade-seed-discussions',
    },
    body: JSON.stringify({ query, variables }),
  });
  const json = await res.json();
  if (json.errors) {
    const err = new Error('GraphQL errors: ' + JSON.stringify(json.errors));
    err.body = json;
    throw err;
  }
  return json.data;
}

async function main() {
  const repoInfo = await gql(`
    query($owner: String!, $name: String!) {
      repository(owner: $owner, name: $name) {
        id
        discussionCategories(first: 25) {
          nodes { id name }
        }
        discussions(first: 100) {
          nodes { id title category { name } }
        }
      }
    }
  `, { owner: OWNER, name: REPO });

  const repoId = repoInfo.repository.id;

  const categoryId = {};
  for (const n of repoInfo.repository.discussionCategories.nodes) {
    categoryId[n.name] = n.id;
  }

  const existing = new Map();
  for (const n of repoInfo.repository.discussions.nodes) {
    existing.set(`${n.category.name}::${n.title}`, n);
  }

  for (const post of POSTS) {
    const catId = categoryId[post.category];
    if (!catId) {
      console.error(`✗ Category not found: ${post.category} (available: ${Object.keys(categoryId).join(', ')})`);
      continue;
    }

    const key = `${post.category}::${post.title}`;
    if (existing.has(key)) {
      console.log(`= ${post.category}: "${post.title}" already exists — skipping`);
      continue;
    }

    const bodyPath = path.join(__dirname, post.file);
    const body = fs.readFileSync(bodyPath, 'utf8');

    if (DRY_RUN) {
      console.log(`[dry-run] would create in ${post.category}: "${post.title}"`);
      continue;
    }

    const created = await gql(`
      mutation($repoId: ID!, $catId: ID!, $title: String!, $body: String!) {
        createDiscussion(input: { repositoryId: $repoId, categoryId: $catId, title: $title, body: $body }) {
          discussion { id number url }
        }
      }
    `, { repoId, catId, title: post.title, body });

    const disc = created.createDiscussion.discussion;
    console.log(`+ ${post.category}: "${post.title}"`);
    console.log(`  ${disc.url}`);

    try {
      await gql(`
        mutation($id: ID!) {
          pinDiscussion(input: { discussionId: $id }) {
            pinnedDiscussion { id }
          }
        }
      `, { id: disc.id });
      console.log('  → pinned');
    } catch (e) {
      const msg = (e.message || '').replace(/\s+/g, ' ').slice(0, 120);
      console.log(`  → could not pin (${msg}); pin via the UI if needed`);
    }
  }

  console.log('Done.');
}

main().catch(e => {
  console.error(e);
  process.exit(1);
});
