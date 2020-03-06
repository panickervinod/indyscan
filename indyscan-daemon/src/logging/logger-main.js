const {createLogger, addElasticTransport} = require('./logger-builder')

const logger = createLogger('main', process.env.LOG_LEVEL)

const {LOG_ES_URL} = process.env

if (LOG_ES_URL) {
  addElasticTransport(logger, process.env.LOG_ES_URL, 'logs-daemon', 'debug')
}

module.exports = logger
