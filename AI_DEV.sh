
#!/bin/bash

# 1. Define Version and Release Info
DOC_VERSION="v1.0.0-docs"
RELEASE_TITLE="📚 Protocol Update: AI Development Guidelines"
RELEASE_NOTES="
## 🚀 Official AI Development Guidelines

We have established a standardized protocol for AI-assisted development to ensure code quality, security, and stability.

### 📄 New File: \`AI_DEV_GUIDELINES.md\`
This document contains the **System Prompts** (English & Persian) that must be used when generating code for this repository.

### ✨ Key Standards Enforced:
* **Immutability:** Preventing regressions in existing code.
* **Minimal Dependencies:** Prioritizing native Bash solutions.
* **Security:** Mandatory audits for every code snippet.
* **Dual Language:** Support for both English and Persian workflows.
"

# 2. Stage and Commit the new file
echo ">> Staging AI_DEV_GUIDELINES.md..."
git add AI_DEV_GUIDELINES.md
git commit -m "docs: add comprehensive AI development guidelines (En/Fa)"

# 3. Create a Git Tag
echo ">> Creating Tag $DOC_VERSION..."
git tag -a "$DOC_VERSION" -m "Release $DOC_VERSION: Added AI Guidelines"

# 4. Push Changes and Tags to GitHub
echo ">> Pushing to Origin..."
git push origin main
git push origin "$DOC_VERSION"

# 5. Create GitHub Release (Requires GitHub CLI 'gh')
if command -v gh &> /dev/null; then
    echo ">> Creating GitHub Release automatically..."
    gh release create "$DOC_VERSION" \
       --title "$RELEASE_TITLE" \
       --notes "$RELEASE_NOTES"
    echo "✅ Release created successfully on GitHub!"
else
    echo "⚠️  GitHub CLI (gh) not found."
    echo ">> Please manually create a release on GitHub for tag: $DOC_VERSION"
    echo ">> Use the Release Notes provided in the script above."
fi
