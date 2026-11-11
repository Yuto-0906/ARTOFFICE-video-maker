import { Component, type ErrorInfo, type ReactNode } from "react";

interface ErrorBoundaryProps {
  children: ReactNode;
}

interface ErrorBoundaryState {
  error: Error | null;
}

export default class ErrorBoundary extends Component<ErrorBoundaryProps, ErrorBoundaryState> {
  state: ErrorBoundaryState = { error: null };

  static getDerivedStateFromError(error: Error): ErrorBoundaryState {
    return { error };
  }

  componentDidCatch(error: Error, info: ErrorInfo) {
    console.error("ARTOFFICE frontend error", error, info.componentStack);
  }

  render() {
    if (!this.state.error) return this.props.children;

    return (
      <main className="fatal-error" role="alert">
        <h1>エラーが起きました</h1>
        <p className="muted">再読み込みすると，保存していない変更は失われます。不具合を報告するときは下の内容を添えてください。</p>
        <pre>{this.state.error.stack || this.state.error.message}</pre>
        <button className="primary" onClick={() => window.location.reload()}>再読み込み</button>
      </main>
    );
  }
}
