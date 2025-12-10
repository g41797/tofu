function setupCodeScrollbars() {
    const codeWrappers = document.querySelectorAll('.md-typeset pre');

    codeWrappers.forEach((wrapper) => {
        const codeContent = wrapper.querySelector(':scope > code');
        if (!codeContent) return;

        // Avoid duplicates
        if (wrapper.dataset.topScrollbarInitialized === '1') return;
        wrapper.dataset.topScrollbarInitialized = '1';

        // Create top scrollbar container
        const topScrollbar = document.createElement('div');
        topScrollbar.className = 'code-top-scrollbar';

        // Create inner filler that matches code scroll width
        const inner = document.createElement('div');
        inner.className = 'code-top-scrollbar-inner';
        topScrollbar.appendChild(inner);

        // Insert top scrollbar before code content
        wrapper.insertBefore(topScrollbar, codeContent);

        // Function to sync the scroll width of inner element
        function syncWidth() {
            inner.style.width = codeContent.scrollWidth + 'px';
        }

        // Initial sync
        syncWidth();

        // Sync scroll: bottom -> top
        codeContent.addEventListener('scroll', () => {
            if (Math.abs(topScrollbar.scrollLeft - codeContent.scrollLeft) > 1) {
                topScrollbar.scrollLeft = codeContent.scrollLeft;
            }
        });

        // Sync scroll: top -> bottom
        topScrollbar.addEventListener('scroll', () => {
            if (Math.abs(codeContent.scrollLeft - topScrollbar.scrollLeft) > 1) {
                codeContent.scrollLeft = topScrollbar.scrollLeft;
            }
        });

        // Re-sync width on content changes/resize
        const resizeObserver = new ResizeObserver(syncWidth);
        resizeObserver.observe(codeContent);

        // Also handle window resize
        window.addEventListener('resize', syncWidth);
    });
}

// Initial load
document.addEventListener('DOMContentLoaded', setupCodeScrollbars);

// Handle Material for MkDocs instant navigation
if (typeof document$ !== 'undefined') {
    document$.subscribe(() => {
        // Small delay to ensure content is fully rendered
        setTimeout(setupCodeScrollbars, 100);
    });
} else {
    // Fallback: use MutationObserver for content changes
    const observer = new MutationObserver(() => {
        setupCodeScrollbars();
    });
    observer.observe(document.body, {
        childList: true,
        subtree: true
    });
}
