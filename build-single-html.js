#!/usr/bin/env node
import fs from 'fs';
import path from 'path';
import { fileURLToPath } from 'url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));

function getMimeType(ext) {
  const mimes = {
    '.js': 'application/javascript',
    '.css': 'text/css',
    '.svg': 'image/svg+xml',
    '.png': 'image/png',
    '.jpg': 'image/jpeg',
    '.jpeg': 'image/jpeg',
    '.gif': 'image/gif',
    '.webp': 'image/webp',
    '.woff': 'font/woff',
    '.woff2': 'font/woff2',
  };
  return mimes[ext.toLowerCase()] || 'application/octet-stream';
}

function encodeFileAsDataUrl(filePath) {
  const ext = path.extname(filePath);
  const data = fs.readFileSync(filePath);
  const mimeType = getMimeType(ext);
  return `data:${mimeType};base64,${data.toString('base64')}`;
}

function resolveAssetPath(refPath, distDir, baseDir = null) {
  if (refPath.startsWith('/')) {
    // Absolute path from dist
    const fullPath = path.join(distDir, refPath.substring(1));
    return fs.existsSync(fullPath) ? fullPath : null;
  } else if (baseDir) {
    // Relative path
    const fullPath = path.resolve(path.dirname(baseDir), refPath);
    return fs.existsSync(fullPath) ? fullPath : null;
  }
  return null;
}

function inlineResources(html, distDir, publicDir) {
  let result = html;
  const cache = new Map();
  
  // Helper to get file content
  const getFile = (filePath) => {
    if (!cache.has(filePath)) {
      try {
        cache.set(filePath, fs.readFileSync(filePath, 'utf-8'));
      } catch {
        return null;
      }
    }
    return cache.get(filePath);
  };
  
  const getDataUrl = (filePath) => {
    try {
      return encodeFileAsDataUrl(filePath);
    } catch {
      return null;
    }
  };
  
  // 1. Inline <link> stylesheets
  result = result.replace(/<link([^>]*?)href=["']([^"']+)["']([^>]*)>/g, (match, pre, href, post) => {
    const resolved = resolveAssetPath(href, distDir);
    if (resolved && resolved.endsWith('.css')) {
      const css = getFile(resolved);
      if (css) {
        return `<style>${css}</style>`;
      }
    }
    return match;
  });
  
  // 2. Inline <script> modules
  result = result.replace(/<script([^>]*?)src=["']([^"']+)["']([^>]*)>/g, (match, pre, src, post) => {
    const resolved = resolveAssetPath(src, distDir);
    if (resolved && resolved.endsWith('.js')) {
      const js = getFile(resolved);
      if (js) {
        // Keep type="module" attribute
        const typeAttr = post.includes('type=') ? '' : ' type="module"';
        return `<script${typeAttr}>${js}</script>`;
      }
    }
    return match;
  });
  
  // 3. Replace image/asset src attributes
  result = result.replace(/src=["']([^"']+)["']/g, (match, src) => {
    const resolved = resolveAssetPath(src, distDir) || 
                     (src === '/vite.svg' && path.join(publicDir, 'vite.svg'));
    
    if (resolved && fs.existsSync(resolved)) {
      const ext = path.extname(resolved).toLowerCase();
      if (['.png', '.jpg', '.jpeg', '.gif', '.webp', '.svg'].includes(ext)) {
        const dataUrl = getDataUrl(resolved);
        if (dataUrl) {
          return `src="${dataUrl}"`;
        }
      }
    }
    return match;
  });
  
  // 4. Remove preconnect/prefetch links
  result = result.replace(/<link[^>]*rel=["'](preconnect|prefetch|dns-prefetch)["'][^>]*>/g, '');
  
  // 5. Remove favicon links that reference /vite.svg (will be handled above)
  result = result.replace(/<link([^>]*?)href=["']\/vite\.svg["']([^>]*)>/g, (match) => {
    // Already converted in src replacement, just remove the link
    return '';
  });
  
  return result;
}

async function main() {
  const distDir = path.join(__dirname, 'dist');
  const publicDir = path.join(__dirname, 'public');
  const indexHtmlPath = path.join(distDir, 'index.html');
  
  if (!fs.existsSync(indexHtmlPath)) {
    console.error(`❌ dist/index.html not found`);
    console.error(`   Make sure to run: pnpm build`);
    process.exit(1);
  }
  
  console.log('📦 Bundling all resources into single HTML...');
  let html = fs.readFileSync(indexHtmlPath, 'utf-8');
  
  html = inlineResources(html, distDir, publicDir);
  
  const outputPath = path.join(distDir, 'FolkSplash.html');
  fs.writeFileSync(outputPath, html);
  
  const stats = fs.statSync(outputPath);
  const sizeMB = (stats.size / 1024 / 1024).toFixed(2);
  const sizeKB = (stats.size / 1024).toFixed(2);
  
  console.log(`✅ Generated: ${path.relative(__dirname, outputPath)}`);
  console.log(`📊 Size: ${sizeMB}MB (${sizeKB}KB)`);
}

main().catch(err => {
  console.error('❌ Error:', err.message);
  process.exit(1);
});
