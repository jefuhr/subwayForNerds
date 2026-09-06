import React from 'react';
import { createRoot } from 'react-dom/client';
import App from './App';
import './styles.css';
import { base } from './platform';

createRoot(document.getElementById('root')!).render(<React.StrictMode><App /></React.StrictMode>);
if ('serviceWorker' in navigator && import.meta.env.PROD) {
  window.addEventListener('load', () => { navigator.serviceWorker.register(base + 'sw.js', { scope: base }).catch(() => {}); });
}
