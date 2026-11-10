// Apply the saved theme before styles paint, including the page canvas.
'use strict';
try {
  document.documentElement.classList.toggle('dark', localStorage.getItem('deployment-theme') === 'dark');
} catch {}
