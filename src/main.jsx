import React from 'react'
import ReactDOM from 'react-dom/client'
import App from '@/App.jsx'
import '@/index.css'
// reload-trigger: force full module graph re-evaluation (clears stale HMR cache)

ReactDOM.createRoot(document.getElementById('root')).render(
  <App />
)