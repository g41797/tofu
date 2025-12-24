// Hero page theme toggle functionality
document.addEventListener('DOMContentLoaded', function() {
  const toggleButton = document.getElementById('hero-theme-toggle');

  if (!toggleButton) return; // Only run on hero page

  // Get the current theme from the body's data attribute
  function getCurrentTheme() {
    return document.body.getAttribute('data-md-color-scheme') || 'default';
  }

  // Set the theme
  function setTheme(theme) {
    document.body.setAttribute('data-md-color-scheme', theme);
    // Store preference in localStorage
    localStorage.setItem('data-md-color-scheme', theme);

    // Also update the palette toggle if it exists (for other pages)
    const paletteInputs = document.querySelectorAll('[data-md-color-scheme]');
    paletteInputs.forEach(input => {
      if (input.getAttribute('data-md-color-scheme') === theme) {
        input.checked = true;
      }
    });
  }

  // Toggle theme
  function toggleTheme() {
    const currentTheme = getCurrentTheme();
    const newTheme = currentTheme === 'default' ? 'slate' : 'default';
    setTheme(newTheme);
  }

  // Add click event listener
  toggleButton.addEventListener('click', toggleTheme);

  // Initialize theme from localStorage if available
  const savedTheme = localStorage.getItem('data-md-color-scheme');
  if (savedTheme) {
    setTheme(savedTheme);
  }
});
