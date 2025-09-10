# Installing and Using the Hugo Learn Theme for Zig Project Documentation

This guide explains how to install the Hugo **Learn** theme for a documentation site hosted on GitHub Pages for your Zig async message communication project. It requires no HTML or CSS knowledge and uses simple Markdown and configuration files.

## Prerequisites
- A GitHub repository with a Zig project.
- [Hugo installed](https://gohugo.io/installation/) on your system.
- Git installed and configured.
- GitHub Pages enabled for the repository, set to use the `main` branch and `/docs` folder (see [GitHub Pages setup](#github-pages-setup) below).

## Step 1: Initialize Hugo Site (if not already done)
1. Navigate to your repository’s root directory:
   ```bash
   cd path/to/your/repository
   ```
2. Create a Hugo site in the `docs` folder:
   ```bash
   hugo new site docs
   cd docs
   ```

## Step 2: Add the Learn Theme
1. Add the Learn theme as a Git submodule:
   ```bash
   git submodule add https://github.com/matcornic/hugo-theme-learn.git themes/learn
   ```
   This downloads the theme into `docs/themes/learn`.

## Step 3: Configure the Learn Theme
1. Open `docs/hugo.toml` in a text editor (e.g., VS Code, Notepad).
2. Add the following configuration:
   ```toml
   baseURL = "https://<username>.github.io/<repository>/"
   languageCode = "en-us"
   title = "Zig Async Message Communication"
   theme = "learn"

   [params]
     description = "Documentation for Zig async messaging"
     author = "<Your Name>"
     themeVariant = "blue"  # Options: green, blue, red
     editURL = "https://github.com/<username>/<repository>/edit/main/docs/content"
     showVisitedLinks = true  # Highlights visited links
   ```
3. Replace `<username>`, `<repository>`, and `<Your Name>` with your GitHub username, repository name, and your name or project alias.

## Step 4: Add Documentation Content
1. Create a homepage in `docs/content/_index.md`:
   ```markdown
   ---
   title: "Zig Async Messaging Docs"
   date: 2025-09-10
   draft: false
   ---

   # Welcome to Zig Async Messaging

   Documentation for the async message communication system built in Zig.

   ## Features
   - Asynchronous message passing
   - High-performance Zig implementation
   - Scalable architecture

   ## Getting Started
   Explore the [Installation Guide](/docs/installation/) or [API Reference](/docs/api/).
   ```
2. Create a sample page in `docs/content/docs/installation.md`:
   ```markdown
   ---
   title: "Installation"
   date: 2025-09-10
   draft: false
   ---

   ## Installing the Zig Async Messaging Library

   1. Clone the repository:
      ```bash
      git clone https://github.com/<username>/<repository>.git
      ```
    2. Build with Zig:
       ```zig
       zig build
       ```
    3. Follow the [Quick Start](/docs/quickstart/) guide.
   ```
   The Learn theme automatically generates a sidebar menu based on the `content/` folder structure.

## Step 5: Test Locally
1. From the `docs` directory, run:
   ```bash
   hugo server
   ```
2. Open `http://localhost:1313` in your browser to preview the site.
3. Verify the Learn theme’s layout (sidebar, code highlighting, clean design).

## Step 6: Build the Site
1. Generate static files:
   ```bash
   hugo
   ```
   This creates the site in `docs/public`.
2. Move files to the `docs` root for GitHub Pages:
   ```bash
   mv public/* .
   rm -rf public
   ```

## Step 7: Commit and Push
1. Commit and push changes to GitHub:
   ```bash
   git add .
   git commit -m "Add Hugo site with Learn theme"
   git push origin main
   ```

## Step 8: Verify GitHub Pages
1. Ensure GitHub Pages is enabled:
    - Go to **Settings > Pages** in your repository.
    - Set **Source** to `main` branch and `/docs` folder.
    - Save if not already configured.
2. Visit `https://<username>.github.io/<repository>` after a few minutes to confirm the site is live.

## Tips for Managing Content
- **Add Pages**: Create new `.md` files in `docs/content/` or subfolders (e.g., `docs/content/docs/api.md`) to expand documentation. The sidebar updates automatically.
- **Write Zig Code**: Use triple backticks for syntax-highlighted code:
  ```markdown
  ```zig
  const std = @import("std");
  pub fn sendMessage(msg: []const u8) void {
      std.debug.print("Sending: {s}\n", .{msg});
  }
  ```
  ```
- **Customize Look**: Change `themeVariant` in `config.toml` (e.g., `green`, `red`) to adjust colors without coding.
- **Learn More**: Visit the [Learn theme documentation](https://learn.netlify.app/) for additional settings, all configurable via `config.toml`.

## Troubleshooting
- **Site Not Loading**: Check `baseURL` in `config.toml` matches your GitHub Pages URL.
- **Theme Not Applied**: Ensure `theme = "learn"` in `config.toml` and `themes/learn` exists.
- **Broken Links**: Verify file paths in Markdown (e.g., `/docs/installation/`) match `content/` structure.

For further help, refer to the [Learn theme documentation](https://learn.netlify.app/) or ask for assistance with specific Zig documentation content.
