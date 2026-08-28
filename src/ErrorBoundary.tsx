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
        <p className="eyebrow">予期しないエラー</p>
        <h1>画面の表示中に問題が発生しました。</h1>
        <p>プロジェクトを保存していない場合は，この画面を閉じずに次の内容を控えてください。</p>
        <pre>{this.state.error.stack || this.state.error.message}</pre>
        <button className="primary" onClick={() => window.location.reload()}>アプリを再読み込み</button>
      </main>
    );
  }
}
