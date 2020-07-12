import React from 'react'
import App, { Container } from 'next/app'
import { Container as SemanticContainer } from 'semantic-ui-react'
import { CSSTransition } from 'react-transition-group'

export default class MyApp extends App {
  static async getInitialProps ({ Component, router, ctx }) {
    let pageProps = {}
    if (Component.getInitialProps) {
      pageProps = await Component.getInitialProps(ctx)
    }
    return { pageProps }
  }


  render () {
    const { Component, pageProps } = this.props
    const { ledger, network } = pageProps
    return (
      <Container>
        <title>HL Indy Tx Explorer</title>
        <SemanticContainer>
          <CSSTransition key={JSON.stringify({ ledger, network })} appear={true} in={true} timeout={300}
                         classNames="pageanimation">
            <Component {...pageProps} />
          </CSSTransition>
        </SemanticContainer>
      </Container>
    )
  }
}
