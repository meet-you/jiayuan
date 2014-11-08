
# /*
#   Db
# */
# Author: yuhan.wyh<yuhan.wyh@alibaba-inc.com>
# Create: Tue Apr 22 2014 11:21:06 GMT+0800 (CST)
#

"use strict"

mysql = null
os    = require 'options-stream'
log   = null
pipe  = require 'event-pipe'

db    = null
pool  = null

BEGIN    =
  """
  SET autocommit = 0;
  """
RESET    =
  """
  SET autocommit = 1;
  """
COMMIT   =
  """
  COMMIT;
  """
ROLLBACK = 
  """
  ROLLBACK;
  """

dbOpt    =
  # 当没有连接可用时，若进行查询，则放入队列，等待连接可用时连接.
  waitForConnections : true

class Db

  # 初始化数据库连接信息
  init : ( options ) ->
    { @log } = options
    mysql = options.mysql or require 'mysql' #/* istanbul ignore next */
    { host, port, user, password, database } = options.database
    dbCfg =
      host : host
      port : port
      user : user
      password : password
      database : database
    dbCfg = os dbCfg, dbOpt
    @_initConnectPool dbCfg

  # 初始化连接池
  _initConnectPool : ( dbCfg ) ->
    { log } = @
    log.info info : 'create mysql connection pool'
    pool = mysql.createPool dbCfg
    pool.on 'error', ( err ) =>
      if err.code is 'PROTOCOL_CONNECTION_LOST'
        log.warn info : 'mysql connection lost and try to reconnect mysql server'
        @_initConnectPool dbCfg
      else
        # TODO:其他异常处理
        log.error info : "db error:#{JSON.stringify err}"
        throw err

  # sql转义
  escapeQuery : ( query, values ) ->
    # emptyRow = []
    if not values
      sql = query
    else
      sql = query.replace /\:(\w+)/g, (txt, key) =>
        if values.hasOwnProperty key
          return pool.escape values[key]
        else
          return null
    sql : sql

  query : ( sql, where, cb ) ->
    @_wrapQuery sql, where, cb

  # 使用事务执行sql
  transactionQuery : ( sqlList, callback ) ->
    ep   = pipe()
    that = @
    { log }    = @
    connection = null
    options    = {}
    ep.on 'error', ( errors ) ->
      log.error info : "#{@container.stepMessage} with error:\"#{JSON.stringify errors}\""
      connection.query ROLLBACK, () ->
        log.warn info : 'transaction rollback!'
        connection.release()
        connection.query RESET, ( err ) ->
          if err
            connection.destroy()
          callback errors
    # 获取连接
    ep.lazy ->
      # 错误信息, 在error事件中处理
      @stepMessage = 'get db connection'
      that._getConnection @
    ep.lazy ( connect ) ->
      connection   = connect
      options.connection = connect
      @()
    # 开启事务
    ep.lazy ->
      @stepMessage = 'start transaction'
      connection.query BEGIN, @
    for item in sqlList
      do ( item ) ->
        # 并行任务执行
        if Array.isArray item
          ep.lazy ( for argItem in item
              { sql, where } = argItem
              do ( sql, where ) ->
                () ->
                  @stepMessage = 'run sql'
                  that._wrapQuery sql, where, @, options
          )
          ep.lazy ( args... ) ->
            for argItem, index in item
              { cb } = argItem
              error  = null
              # 事务队列执行过程中, 如果需要停止执行, 在当前sql的回调函数抛出一个错误即可.
              # TODO:若回调函数中有异步逻辑, 则可能需要给回调函数一个DB的回调, 以继续流程.
              try
                cb?.apply null, args[ index ]
              catch e
                error = 
                  message : e.message
              @ error
        # 串行任务执行
        else
          { sql, where, cb } = item
          ep.lazy ->
            @stepMessage = 'run sql'
            that._wrapQuery sql, where, @, options
          ep.lazy ( args... ) ->
            error = null
            try
              cb?.apply null, args
            catch e
              error =
                message : e.message
            @ error
    # commit
    ep.lazy ->
      @stepMessage = 'commit'
      connection.query COMMIT, @
    ep.lazy ->
      log.info info : 'commit success!'
      connection.release()
      callback null
      connection.query RESET, ( err ) ->
        connection.destroy() if err
    ep.run()

  # 从连接池中获取连接
  _getConnection : ( cb, retry = 0 ) ->
    that = @
    { log } = @
    pool.getConnection ( err, connection ) ->
      if err
        log.error info : "get connection error:#{JSON.stringify err}"
        # 查询时，若从连接池中获取连接失败，并且重试3次失败后，将错误抛给callback
        if retry++ >= 2
          log.error info : "get connection error after retry 3 times:#{JSON.stringify err}"
          return cb err, null
        else
          setTimeout ->
            that._getConnection cb, retry
          , 200
      else
        cb null, connection

  # query前处理, 包括从连接池中获取链接, 事务连接处理等
  _wrapQuery : (sql, where, cb, options = {} ) ->
    options.autoRelease ?= true
    options.retry ?= 0
    { retry, autoRelease, connection } = options
    that   = @
    # 复用同一个连接, 以便于使用事务和自增ID获取等.
    if connection
      options.autoRelease = false
      @_doQuery sql, where, cb, options
    else
      @_getConnection ( err, connection ) =>
        return cb err if err
        options.connection = connection
        @_doQuery sql, where, cb, options

  # 调用连接对象进行查询
  _doQuery : ( sql, where, cb, options ) ->
    { log } = @
    { autoRelease, connection } = options
    escapedSql = @escapeQuery sql, where
    { sql }    = escapedSql
    do ( sql, connection, autoRelease, cb ) ->
      connection.query sql, ( err, data ) ->
        connection.release() if autoRelease is true
        log.error info : sql if err
        cb err, data

  escape : ( args... ) ->
    pool.escape.apply pool, args

  destroy : ->
    db = null
    if pool then pool.end()

module.exports = ->
  db   ?= new Db

module.exports.Db = Db
