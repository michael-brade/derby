{lookup} = require 'racer/lib/path'
{parse: parseHtml, unescapeEntities, escapeHtml, escapeAttr, isVoid} = require './html'
{modelPath} = markup = require './markup'

empty = -> ''
notFound = (name) -> throw new Error "Can't find view: #{name}"
defaultCtx =
  $depth: 0
  $aliases: {}
  $paths: []
  $i: []

defaultGetFns =
  equal: (a, b) -> a == b
  not: (value) -> !value

defaultSetFns =
  equal: (value) -> [value]
  not: (value) -> [!value]

View = module.exports = ->
  @clear()
  @getFns = Object.create defaultGetFns
  @setFns = Object.create defaultSetFns
  return

View:: =

  clear: ->
    @_views = Object.create @default
    @_renders = {}
    @_inline = ''
    # All automatically created ids start with a dollar sign
    @_idCount = 0

  _uniqueId: -> '$' + (@_idCount++).toString 36

  default:
    doctype: -> '<!DOCTYPE html>'
    root: empty
    charset: -> '<meta charset=utf-8>'
    title$s: empty
    head: empty
    header: empty
    body: empty
    footer: empty
    scripts: empty
    tail: empty

  make: (name, template, templatePath, isString) ->
    stringTemplatePath = templatePath + '$s' if templatePath
    @make name + '$s', template, stringTemplatePath, true  unless isString

    if templatePath && render = @_renders[templatePath]
      @_views[name] = render
      return

    name = name.toLowerCase()
    renderer = (ctx) =>
      renderer = parse this, name, template, isString, onBind
      renderer ctx
    render = (ctx) -> renderer ctx

    @_views[name] = render
    @_renders[templatePath] = render if templatePath

    if name is 'title$s' then onBind = (events, name) ->
      bindEvents events, name, render, ['$_doc', 'prop', 'title']
    return

  _makeAll: (templates, instances) ->
    for name, templatePath of instances
      @make name, templates[templatePath], templatePath
    return

  _find: (name, ns) ->
    views = @_views
    if ns
      ns = ns.toLowerCase()
      return view if view = views["#{ns}:#{name}"]
      segments = ns.split ':'
      if (from = segments.length - 2) >= 0
        for i in [from..0]
          testNs = segments[0..i].join ':'
          return view if view = views["#{testNs}:#{name}"]
      return views[name] || notFound "#{ns}:#{name}"
    return views[name] || notFound name

  get: (name, ns, ctx) ->
    if typeof ns is 'object'
      ctx = ns
      ns = ''
    ctx = if ctx then extend ctx, defaultCtx else Object.create defaultCtx
    @_find(name, ns) ctx

  inline: empty

  fn: (name, fn) ->
    if typeof fn is 'object'
      {get, set} = fn
    else
      get = fn
    @getFns[name] = get
    @setFns[name] = set if set

  render: (@model, ns, ctx, silent) ->
    if typeof ns is 'object'
      silent = ctx
      ctx = ns
      ns = ''

    @_idCount = 0
    @model.__pathMap.clear()
    @model.__events.clear()
    @model.__blockPaths = {}
    @dom.clear()

    title = @get('title$s', ns, ctx)
    rootHtml = @get('root', ns, ctx)
    bodyHtml = @get('header', ns, ctx) + @get('body', ns, ctx) + @get('footer', ns, ctx)
    return if silent

    doc = document
    documentElement = doc.documentElement

    # Remove all current attributes on the documentElement and replace
    # them with the attributes in the rendered rootHtml.
    for attr in documentElement.attributes
      documentElement.removeAttribute attr.name
    # Using the DOM to get the attributes on an <html> tag would require
    # some sort of iframe hack until DOMParser has better browser support.
    # String parsing the html should be simpler and more efficient
    parseHtml rootHtml, start: (tag, tagName, attrs) ->
      return unless tagName is 'html'
      for attr, value of attrs
        documentElement.setAttribute attr, value
      return

    fakeRoot = doc.createElement 'html'
    fakeRoot.innerHTML = bodyHtml
    body = fakeRoot.getElementsByTagName('body')[0]
    documentElement.replaceChild body, doc.body
    doc.title = title

  escapeHtml: escapeHtml
  escapeAttr: escapeAttr


extend = (parent, obj) ->
  out = Object.create parent
  if typeof obj isnt 'object' || Array.isArray(obj)
    return out
  for key of obj
    out[key] = obj[key]
  return out

bindEvents = (events, name, fn, params) ->
  events.push (ctx, modelEvents, dom, pathMap, blockPaths, triggerId) ->
    if ~name.indexOf('(')
      paths = pathFnArgs ctx, name
      return

    return unless path = modelPath ctx, name
    listener = if params.call then params triggerId, pathMap, blockPaths, path else params
    modelEvents.bind pathMap.id(path), listener
    listener.fn = fn
    listener.ctx = ctx.$stringCtx || ctx
bindEventsById = (events, name, fn, attrs, method, prop, isBlock) ->
  bindEvents events, name, fn, (triggerId, pathMap, blockPaths, path) ->
    id = attrs._id || attrs.id
    blockPaths[id] = pathMap.id path  if isBlock
    return [id, method, prop]
bindEventsByIdString = (events, name, fn, attrs, method, prop) ->
  bindEvents events, name, fn, (triggerId) ->
    id = triggerId || attrs._id || attrs.id
    return [id, method, prop]

addId = (view, attrs) ->
  unless attrs.id?
    attrs.id = -> attrs._id = view._uniqueId()

# Remove leading whitespace and newlines from a string. Note that trailing
# whitespace is not removed in case whitespace is desired between lines
View.trim = trim = (s) -> if s then s.replace /\n\s*/g, '' else ''

# True if remaining text does not immediately close the current tag
wrapRemainder = (tagName, remainder) ->
  return false unless remainder
  return !(new RegExp '^<\/' + tagName, 'i').test(remainder)

openPlaceholder = ///^
  ([\s\S]*?)  # Before the placeholder
  (\({2,3}|\{{2,3})  # Opening of placeholder
  ([\s\S]*)  # Remainder
///

placeholderContent = ///^
  \s*([\#/]?)  # Start or end block
  (if|else|elseif|unless|each|with)?  # Block type
  \s*(  # Name of context object
    [^\s(>]*
    (?: \s* \( [\s\S]* \) )?
  )
  (?:\s+as\s+:([^\s>]+))?  # Alias name
  (?:\s*>\s*([^\s]+)\s*)?  # Partial name
///

matchParens = (text, num, i) ->
  i++
  while num
    close = text.indexOf ')', i
    open = text.indexOf '(', i
    hasClose = ~close
    hasOpen = ~open
    if hasClose && (!hasOpen || (close < open))
      i = close + 1
      num--
      continue
    else if hasOpen
      i = open + 1
      num++
      continue
    else
      return
  return i

extractPlaceholder = (text) ->
  return unless match = openPlaceholder.exec text
  pre = match[1]
  open = match[2]
  remainder = match[3]
  bound = open.charAt(0) is '('
  openLen = open.length
  escaped = openLen is 2

  if bound
    return unless end = matchParens remainder, openLen, 0
    endInner = end - openLen

  else
    close = if escaped then '}}' else '}}}'
    return unless ~(endInner = remainder.indexOf close)
    end = endInner + openLen

  inner = remainder[0...endInner]
  post = remainder[end..]
  return unless content = placeholderContent.exec inner    

  return {
    pre: trim pre
    post: trim post
    bound: bound
    escaped: escaped
    hash: content[1]
    type: content[2]
    name: content[3]
    alias: content[4]
    partial: content[5]?.toLowerCase()
  }

fnCall = ///^
  ([^(]+)  # Function name
  \s* \( \s*
  ([\s\S]*?)  # Arguments
  \s* \) \s*
$///
argSeparator = /\s*([,(])\s*/g
notSeparator = /[^,\s]/g

fnCallError = (name) ->
  throw new Error 'malformed view function call: ' + name

fnArgs = (inner) ->
  args = []
  lastIndex = 0
  while match = argSeparator.exec inner
    # Find nested function calls
    if match[1] is '('
      end = matchParens inner, 1, argSeparator.lastIndex
      args.push inner[lastIndex...end]
      notSeparator.lastIndex = end
      lastIndex = argSeparator.lastIndex =
        if notSeparator.test inner then notSeparator.lastIndex - 1 else end
      continue

    # Push an argument
    args.push inner[lastIndex...match.index]
    lastIndex = argSeparator.lastIndex

  # Push the last argument
  if last = inner[lastIndex..]
    args.push last
  return args

fnValue = (view, ctx, model, name) ->
  fnCallError name unless match = fnCall.exec name
  fnName = match[1]
  args = fnArgs match[2]

  # Get values for each argument
  for arg, i in args

    # Support null, true, and false -- the same keyword values as JSON 
    if arg is 'null'
      args[i] = null
      continue

    if arg is 'true'
      args[i] = true
      continue

    if arg is 'false'
      args[i] = false
      continue

    firstChar = arg.charAt 0

    if firstChar is "'"
      fnCallError name unless match = /^'(.*)'$/.exec arg
      args[i] = match[1]
      continue

    if firstChar is '"'
      fnCallError name unless match = /^"(.*)"$/.exec arg
      args[i] = match[1]
      continue

    if /^[-\d]/.test firstChar
      # JavaScript's isNaN will be false for any number or string
      # that could be a number, such as '3'. Otherwise, it is true
      fnCallError name if isNaN arg
      # Cast into a number
      args[i] = +arg
      continue

    if firstChar is '[' || firstChar is '{'
      throw new Error 'object literals not supported in view function call: ' + name

    args[i] = dataValue view, ctx, model, arg

  unless fn = view.getFns[fnName]
    throw new Error 'view function "' + fnName + '" not found for call: ' + name

  return fn args...

dataValue = (view, ctx, model, name) ->
  if ~name.indexOf('(')
    return fnValue view, ctx, model, name
  path = modelPath ctx, name
  value = lookup path, ctx
  return value if value isnt undefined
  value = model.get path
  return if value isnt undefined then value else model[path]

notPathArg = ///
  (?:^ ['"-\d[{] )|  # String, number, or object literal
  (?:^ null $)|
  (?:^ true $)|
  (?:^ false $)
///
pathFnArgs = (ctx, name, paths = []) ->
  fnCallError name unless match = fnCall.exec name
  args = fnArgs match[2]

  for arg in args
    if notPathArg.test arg
      continue
    if ~arg.indexOf('(')
      pathFnArgs ctx, arg, paths
      continue
    paths.push modelPath ctx, arg

  return paths

reduceStack = (stack) ->
  html = ['']
  i = 0
  for item in stack
    pushValue = (value, isAttr) ->
      if value && value.call
        i = html.push(value, '') - 1
      else
        html[i] += if isAttr then escapeAttr value else value

    switch item[0]
      when 'start'
        html[i] += '<' + item[1]
        attrs = item[2]
        # Make sure that the id attribute is rendered first
        if 'id' of attrs
          html[i] += ' id='
          pushValue attrs.id, true
        for key, value of attrs
          continue  if key is 'id'
          if value?
            if bool = value.bool
              pushValue bool
              continue
            html[i] += ' ' + key + '='
            pushValue value, true
          else html[i] += ' ' + key
        html[i] += '>'
      when 'chars'
        pushValue item[1]
      when 'end'
        html[i] += '</' + item[1] + '>'
      when 'marker'
        html[i] += '<!--' + item[1]
        pushValue item[2].id
        html[i] += '-->'
  return html


renderer = (view, items, events, onRender) ->
  (ctx, model, triggerPath, triggerId) ->
    if triggerPath && path = ctx.$paths[0]
      _path = path.split '.'
      _triggerPath = triggerPath.split '.'
      indices = ctx.$i.slice()
      index = 0
      for segment, i in _path
        triggerSegment = _triggerPath[i]
        # `(n = +triggerSegment) == n` will be false if segment is NaN
        if segment is '$#' && (n = +triggerSegment) == n
          indices[index++] = n
        else if segment != triggerSegment
          break
      ctx.$i = indices

    model ||= view.model  # Needed, since model parameter is optional
    pathMap = model.__pathMap
    modelEvents = model.__events
    blockPaths = model.__blockPaths
    dom = view.dom
    html = ''
    ctx = onRender ctx if onRender
    for item in items
      html += if item.call then item(ctx, model, triggerPath) || '' else item
    i = 0
    while event = events[i++]
      event ctx, modelEvents, dom, pathMap, blockPaths, triggerId
    return html

parseMatchError = (text, message) ->
  throw new Error message + '\n\n' + text + '\n'

parseMatch = (view, text, match, queues, {onStart, onEnd, onVar}) ->
  {hash, type, name, partial} = match
  {block} = queues.last()
  blockType = block && block.type

  if partial
    if hash
      parseMatchError text, 'partial tag cannot start with ' + hash

  else if type is 'if' || type is 'unless' || type is 'each' || type is 'with'
    if hash is '#'
      startBlock = true
    else if hash is '/'
      endBlock = true
    else
      parseMatchError text, type + ' blocks must begin with a #'

  else if type is 'else' || type is 'elseif'
    if hash
      parseMatchError text, type + ' blocks may not start with ' + hash
    if blockType isnt 'if' && blockType isnt 'elseif' && blockType isnt 'each'
      parseMatchError text, type + ' may only follow if, elseif, or each'
    startBlock = true
    endBlock = true

  else if hash is '/'
    endBlock = true

  else if hash is '#'
    parseMatchError text, '# must be followed by if, unless, each, or with'

  if endBlock
    parseMatchError text, 'Unmatched template end tag' unless block
    match.name = block.name
    endQueue = queues.pop()

  if startBlock
    queues.push queue =
      stack: []
      events: []
      block: match
    queue.closed = endQueue  if endBlock
    onStart queue
  else
    if endBlock
      onStart queues.last()
      onEnd endQueue
    else
      onVar match
  return

extendCtx = (ctx, value, name, alias, index, isArray) ->
  ctx = extend ctx, value
  ctx.this = value
  if alias
    aliases = ctx.$aliases = Object.create ctx.$aliases
    aliases[alias] = ctx.$depth
  if path = modelPath ctx, name, true
    ctx.$paths = [path].concat ctx.$paths
  ctx.$depth++  if name
  if index?
    ctx.$i = ctx.$i.concat index
    isArray = true
  ctx.$paths[0] += '.$#'  if isArray && ctx.$paths[0]
  return ctx

partialValue = (view, ctx, model, name, value, useValue) ->
  if useValue
    value
  else
    if name then dataValue view, ctx, model, name else true

partialFn = (view, name, type, alias, render) ->

  withFn = (ctx, model, triggerPath, triggerId, value, index, useValue) ->
    value = partialValue view, ctx, model, name, value, useValue

    renderCtx = extendCtx ctx, value, name, alias, index
    return render renderCtx, model, triggerPath

  if type is 'var'
    return render

  if type is 'with'
    return withFn

  if type is 'if' || type is 'elseif'
    return (ctx, model, triggerPath, triggerId, value, index, useValue) ->
      value = partialValue view, ctx, model, name, value, useValue

      if (if Array.isArray(value) then value.length else value)
        renderCtx = extendCtx ctx, value, name, alias, index
        return render renderCtx, model, triggerPath
      return

  if type is 'else' || type is 'unless'
    return (ctx, model, triggerPath, triggerId, value, index, useValue) ->
      value = partialValue view, ctx, model, name, value, useValue

      if (Array.isArray(value) && !value.length) || !value
        renderCtx = extendCtx ctx, value, name, alias, index
        return render renderCtx, model, triggerPath
      return

  if type is 'each'
    return (ctx, model, triggerPath, triggerId, value, index, useValue) ->
      value = partialValue view, ctx, model, name, value, useValue

      unless Array.isArray(value)
        return withFn ctx, model, triggerPath, triggerId, value, index, true

      ctx = extendCtx ctx, null, name, alias, null, true

      out = ''
      indices = ctx.$i
      for item, i in value
        renderCtx = extend ctx, item
        renderCtx.this = item
        renderCtx.$i = indices.concat i
        out += render renderCtx, model, triggerPath
      return out

  throw new Error 'Unknown block type'

objectToString = Object::toString

textFn = (view, name, escape) ->
  (ctx, model) ->
    value = dataValue view, ctx, model, name
    text = if typeof value is 'string' then value else
      if `value == null` then '' else
        if value.toString is objectToString
          JSON.stringify value
        else
          value.toString()
    return if escape then escape text else text

blockFn = (view, queue) ->
  return unless queue
  {stack, events, block} = queue
  {name, escaped, type, alias} = block
  render = renderer view, reduceStack(stack), events
  return partialFn view, name, type, alias, render

parseMarkup = (type, attr, tagName, events, attrs, name, invert) ->
  return  unless parser = markup[type][attr]
  if anyParser = parser['*']
    anyOut = anyParser events, attrs, name, invert
  if elParser = parser[tagName]
    elOut = elParser events, attrs, name, invert
  out = if anyOut then extend anyOut, elOut else elOut
  delete attrs[attr]  if out?.del
  return out

pushChars = (stack, text) ->
  stack.push ['chars', text]  if text

pushVarFns = (view, stack, fn, fn2, name, escaped) ->
  if fn
    pushChars stack, fn
    pushChars stack, fn2
  else
    pushChars stack, textFn view, name, escaped && escapeHtml

pushVar = (view, ns, stack, events, remainder, match, fn, fn2) ->
  {name, escaped, partial} = match
  if partial
    type = match.type || 'var'
    fn = partialFn view, name, type, match.alias, view._find(partial, ns)

  if match.bound
    last = stack[stack.length - 1]
    wrap = match.pre ||
      !last ||
      (last[0] != 'start') ||
      isVoid(tagName = last[1]) ||
      wrapRemainder(tagName, remainder)

    if wrap
      stack.push ['marker', '', attrs = {}]
    else
      for attr of attrs = last[2]
        parseMarkup 'boundParent', attr, tagName, events, attrs, name
    addId view, attrs

    bindEventsById events, name, fn, attrs, 'html', !fn && escaped, true
    bindEventsById events, name, fn2, attrs, 'append'  if fn2

  pushVarFns view, stack, fn, fn2, name, escaped
  stack.push ['marker', '$', {id: -> attrs._id}]  if wrap

pushVarString = (view, ns, stack, events, remainder, match, fn, fn2) ->
  {name, partial} = match
  if partial
    type = match.type || 'var'
    fn = partialFn view, name, type, match.alias, view._find(partial + '$s', ns)
  bindOnce = (ctx) ->
    ctx.$onBind events, name
    bindOnce = empty
  if match.bound then events.push (ctx) -> bindOnce ctx
  pushVarFns view, stack, fn, fn2, name

parse = null
forAttr = (view, viewName, stack, events, tagName, attrs, attr, value) ->
  if match = extractPlaceholder value
    {pre, post, name, bound, partial} = match
    
    invert = /^\s*!\s*$/.test pre
    if (pre && !invert) || post || partial
      # Attributes must be a single string, so create a string partial
      addId view, attrs
      render = parse view, viewName, value, true, (events, name) ->
        bindEventsByIdString events, name, render, attrs, 'attr', attr

      attrs[attr] = if attr is 'id'
        (ctx, model) -> attrs._id = escapeAttr render(ctx, model)
      else
        (ctx, model) -> escapeAttr render(ctx, model)
      return

    out = parseMarkup('bound', attr, tagName, events, attrs, name, invert) || {}

    if bound
      addId view, attrs
      fn = '$inv'  if invert
      bindEventsById events, name, fn, attrs, (out.method || 'attr'), (out.property || attr)

    unless out.del
      attrs[attr] = if out.bool
          bool: (ctx, model) ->
            if !dataValue(view, ctx, model, name) == invert then ' ' + attr else ''
        else textFn view, name, escapeAttr

  out = parseMarkup 'attr', attr, tagName, events, attrs, value
  addId view, attrs  if out?.addId

parse = (view, viewName, template, isString, onBind) ->
  queues = [{stack: stack = [], events: events = []}]
  queues.last = -> queues[queues.length - 1]

  if isString
    push = pushVarString
    onRender = (ctx) ->
      return ctx if ctx.$stringCtx
      ctx = Object.create ctx
      ctx.$onBind = onBind
      ctx.$stringCtx = ctx
      return ctx
  else
    push = pushVar

  ns = if ~(index = viewName.lastIndexOf ':') then viewName[0...index] else ''

  start = (tag, tagName, attrs) ->
    if parser = markup.element[tagName]
      out = parser(events, attrs)
      addId view, attrs  if out?.addId

    for attr, value of attrs
      forAttr view, viewName, stack, events, tagName, attrs, attr, value

    stack.push ['start', tagName, attrs]

  chars = (text, isRawText, remainder) ->
    if isRawText || !(match = extractPlaceholder text)
      text = if isString then unescapeEntities trim text else trim text
      pushChars stack, text
      return

    {pre, post} = match
    pre = unescapeEntities pre  if isString
    pushChars stack, pre

    parseMatch view, text, match, queues,
      onStart: (queue) ->
        {stack, events, block} = queue
      onEnd: (queue) ->
        fn = blockFn view, queue
        fn2 = blockFn view, queue.closed
        push view, ns, stack, events, (post || remainder), queue.block, fn, fn2
      onVar: (match) ->
        push view, ns, stack, events, (post || remainder), match

    chars post  if post

  end = (tag, tagName) ->
    stack.push ['end', tagName]

  if isString
    chars template
  else
    parseHtml template, {start, chars, end}

  return renderer view, reduceStack(stack), events, onRender
