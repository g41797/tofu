document.addEventListener('DOMContentLoaded', function () {
    const header = document.querySelector('main h1'); // Insert below the main title
    if (header) {
        const printButton = document.createElement('button');
        printButton.textContent = '🖨️ Print this page';
        printButton.className = 'print-button';
        printButton.addEventListener('click', function () {
            window.print();
        });
        header.before(printButton); // Add the button after the title
    }
});