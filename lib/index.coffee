
MYSQL =
  host : 'perterpon.mysql.rds.aliyuncs.com'
  user : 'girl'
  password : 'pon423904'
  database : 'girl'

exec     = require( 'child_process' ).exec

request  = require 'request'

thunkify = require 'thunkify'

cheerio  = require 'cheerio'

db       = require( './core/db' )()

co       = require 'co'

request  = thunkify request

count    = 1

class Index

  constructor : ->
    db.init { database : MYSQL, log : console }
    db.query = thunkify db.query
    exec     = thunkify exec

  run : co -->
    while true
      @beginCycle()
      yield @sleep 10 * 1000

  beginCycle : co -->
    try
      count++
      list = yield exec "curl -d 'sex=f&key=&stc=1%3A3301%2C2%3A18.26%2C23%3A1&sn=default&sv=1&p=#{count}&f=select&listStyle=bigPhoto&pri_uid=0&jsversion=v5' http://search.jiayuan.com/v2/search_v2.php"
      [ body ] = list
      resList = JSON.parse body.replace( '##jiayser##', '' ).replace '##jiayser##//', ''
      { userInfo, count } = resList
      data = []
      for item, idx in userInfo
        { realUid:uid } = item
        yield @sleep 1000
        detailReqOption =
          url : "http://www.jiayuan.com/#{uid}"
          headers : 
            Host: 'www.jiayuan.com'
            'User-Agent' : 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_10_0) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/38.0.2125.111 Safari/537.36'
        detail  = yield request detailReqOption
        [ trash, body ] = detail
        data.push @parseDetail uid, body
      sql = 
        """
        INSERT INTO gril (
          source,
          name,
          age,
          constellation,
          educational,
          portrait_url,
          address,
          high,
          con_id,
          images_url,
          weight
        )
        VALUES :data
        """
      yield db.query sql, { data }
    catch e
      console.log e

  getDetail : thunkify ( uid, done ) ->
    reqOption =
      url : "http://www.jiayuan.com/#{uid}"
      headers : 
        Host: 'www.jiayuan.com'
        'User-Agent' : 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_10_0) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/38.0.2125.111 Safari/537.36'
    detail = request reqOption, done

  parseDetail : ( uid, body ) ->
    $ = cheerio.load body
    portrait_url = $( '.user_operation .user_pic img' ).attr 'src'
    name         = $( '.my_information h1 span' ).text().replace '和我聊天', ''
    nameInfo     = $( '.my_information h2' ).text().replace( '查看详细信息>>', '' ).split '，'
    [ sex, age, constellation, address ] = nameInfo
    address     ?= ''
    address      = address.replace '来自', ''
    high         = $( $( $( '.my_information .details li' )[ 0 ] ).find( 'span' )[ 0 ] ).text().replace( '身高：', '' ).replace '厘米', ''
    educational  = $( $( $( '.my_information .details li' )[ 0 ] ).find( 'span' )[ 0 ] ).text().replace '学历：', ''
    imgBox       = $ '.img_box img'
    images_url   = (
      for item in imgBox
        $( item ).attr 'src'
    ).toString()
    weight       = $( $( $( '.claim_content' )[ 1 ] ).find( 'li' )[ 5 ] ).text().replace( '体　　重：', '' ).replace '公斤', ''
    [ 'jiayuan', name, age, constellation, educational, portrait_url, address, high, uid, images_url, weight ]

  sleep : thunkify ( time, done ) ->
    setTimeout done, time

module.exports =
  run : ->
    index = new Index
    index.run()
