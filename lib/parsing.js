var saddle = require('saddle');
var htmlUtil = require('html-util');
var derbyExpressions = require('./derby-expressions');
var templates = require('./templates');
var expressions = derbyExpressions.expressions;

module.exports = {
  createTemplate: createTemplate
, createStringTemplate: createStringTemplate
, createExpression: createExpression
};

// View.prototype._parse is defined here, so that it doesn't have to
// be included in the client if templates are all parsed server-side
templates.View.prototype._parse = function() {
  // Wrap parsing in a try / catch to add context to message when throwing
  try {
    var template;
    if (this.string) {
      template = createStringTemplate(this.source, this);
    } else {
      var source = (this.unminified) ? this.source :
        htmlUtil.minify(this.source).replace(/&sp;/g, ' ');
      template = createTemplate(source, this);
    }
  } catch (err) {
    var message = '\n\nWithin template "' + this.name + '":\n' + this.source;
    throw appendErrorMessage(err, message);
  }
  this.template = template;
  return template;
}

// Modified and shared among the following parse functions. It's OK for this
// to be shared at the module level, since it is only used by synchronous code
var parseNode;

function createTemplate(source, view) {
  parseNode = new ParseNode(view);
  htmlUtil.parse(source, {
    start: parseHtmlStart
  , end: parseHtmlEnd
  , text: parseHtmlText
  , comment: parseHtmlComment
  , other: parseHtmlOther
  });
  return new saddle.Template(parseNode.content);
}

function createStringTemplate(source, view) {
  parseNode = new ParseNode(view);
  parseText(source, parseTextLiteral, parseTextExpression);
  return new saddle.Template(parseNode.content);
}

function parseHtmlStart(tag, tagName, attributes) {
  var attributesMap = parseAttributes(attributes);
  var element;
  if (saddle.VOID_ELEMENTS[tagName]) {
    element = new saddle.Element(tagName, attributesMap);
    parseNode.content.push(element);
  } else {
    parseNode = parseNode.child();
    element = new saddle.Element(tagName, attributesMap, parseNode.content);
    parseNode.parent.content.push(element);
  }
}

function parseAttributes(attributes) {
  var attributesMap;
  for (var key in attributes) {
    if (!attributesMap) attributesMap = new saddle.AttributesMap();

    var value = attributes[key];
    if (value === '' || typeof value !== 'string') {
      attributesMap[key] = new saddle.Attribute(value);
      continue;
    }

    parseNode = parseNode.child();
    parseText(htmlUtil.unescapeEntities(value), parseTextLiteral, parseTextExpression);

    if (parseNode.content.length === 1) {
      var item = parseNode.content[0];
      attributesMap[key] = (item instanceof saddle.Text) ? new saddle.Attribute(item.data) :
        (item.expression instanceof expressions.LiteralExpression) ? new saddle.Attribute(item.expression.value) :
        new saddle.DynamicAttribute(item.expression);

    } else if (parseNode.content.length > 1) {
      var template = new saddle.Template(parseNode.content);
      attributesMap[key] = new saddle.DynamicAttribute(template);

    } else {
      throw new Error('Error parsing ' + key + ' attribute: ' + value);
    }

    parseNode = parseNode.parent;
  }
  return attributesMap;
}

function parseHtmlEnd(tag, tagName) {
  parseNode = parseNode.parent;
  var last = parseNode.last();
  if (!(last instanceof saddle.Element && last.tag === tagName)) {
    throw new Error('Mismatched closing HTML tag: ' + tag);
  }
  if (tagName === 'view') {
    var element = parseNode.content.pop();
    parseViewElement(element);
    return;
  }
  var view = parseNode.view && parseNode.view.views.elementMap[tagName];
  if (view) {
    var element = parseNode.content.pop();
    parseNamedViewElement(element, view, view.name);
  }
}

function parseHtmlText(data) {
  var unescaped = htmlUtil.unescapeEntities(data);
  parseText(unescaped, parseTextLiteral, parseTextExpression);
}

function parseHtmlComment(tag, data) {
  // Only output comments that start with `<!--[` and end with `]-->`
  if (!htmlUtil.isConditionalComment(tag)) return;
  var comment = new saddle.Comment(data);
  parseNode.content.push(comment);
}

function parseHtmlOther(tag) {
  // Parse doctype literally
  var text = new expressions.LiteralExpression(tag);
  parseNode.content.push(text);
}

function parseTextLiteral(data) {
  var text = new saddle.Text(data);
  parseNode.content.push(text);
}

function parseTextExpression(expression) {
  if (expression.meta.blockType) {
    parseBlockExpression(expression);
  } else if (expression.meta.valueType === 'view') {
    parseViewExpression(expression);
  } else {
    parseValueExpression(expression);
  }
}

function parseBlockExpression(expression) {
  var blockType = expression.meta.blockType;

  // Block ending
  if (expression.meta.isEnd) {
    parseNode = parseNode.parent;
    // Validate that the block ending matches an appropriate block start
    var last = parseNode.last();
    var lastExpression = last && (last.expression || (last.expressions && last.expressions[0]));
    if (!(
      lastExpression &&
      (blockType === 'end' && lastExpression.meta.blockType) ||
      (blockType === lastExpression.meta.blockType)
    )) {
      throw new Error('Mismatched closing template tag: ' + expression.meta.source);
    }

  // Continuing block
  } else if (blockType === 'else' || blockType === 'else if') {
    parseNode = parseNode.parent;
    var last = parseNode.last();
    parseNode = parseNode.child();

    if (last instanceof saddle.ConditionalBlock) {
      last.expressions.push(expression);
      last.contents.push(parseNode.content);
    } else if (last instanceof saddle.EachBlock) {
      if (blockType !== 'else') unexpected(expression.meta.source);
      last.elseContent = parseNode.content;
    } else {
      unexpected(expression.meta.source);
    }

  // Block start
  } else {
    var nextNode = parseNode.child();
    var block;
    if (blockType === 'if' || blockType === 'unless') {
      block = new saddle.ConditionalBlock([expression], [nextNode.content]);
    } else if (blockType === 'each') {
      block = new saddle.EachBlock(expression, nextNode.content);
    } else {
      block = new saddle.Block(expression, nextNode.content);
    }
    parseNode.content.push(block);
    parseNode = nextNode;
  }
}

function parseViewElement(element) {
  var nameAttribute = element.attributes.name;
  if (!nameAttribute) {
    throw new Error('The <view> element requires a name attribute');
  }
  delete element.attributes.name;

  if (nameAttribute.template) {
    var viewAttributes = viewAttributesFromElement(element);
    var remaining = element.content;
    var viewPointer = new templates.DynamicViewPointer(nameAttribute.template, viewAttributes);
    finishParseViewElement(viewAttributes, remaining, viewPointer);
  } else {
    var name = nameAttribute.data;
    var view = findView(name);
    parseNamedViewElement(element, view, name);
  }
}

function findView(name) {
  var view = parseNode.view.views.find(name, parseNode.view.at);
  if (!view) throw new Error('No view found for "' + name + '"');
  return view;
}

function parseNamedViewElement(element, view, name) {
  var viewAttributes = viewAttributesFromElement(element);
  var remaining = parseContentAttributes(element.content, view, viewAttributes);
  var viewPointer = new templates.ViewPointer(view.name, viewAttributes, view);
  finishParseViewElement(viewAttributes, remaining, viewPointer);
}

function finishParseViewElement(viewAttributes, remaining, viewPointer) {
  if (!viewAttributes.hasOwnProperty('content') && remaining.length) {
    viewAttributes.content = new templates.ParentWrapper(
      new saddle.Template(remaining)
    );
  }
  parseNode.content.push(viewPointer);
}

function viewAttributesFromElement(element) {
  var viewAttributes = new templates.ViewAttributes();
  for (var key in element.attributes) {
    var attribute = element.attributes[key];
    var camelCased = dashToCamelCase(key);
    viewAttributes[camelCased] =
      (attribute.template instanceof saddle.Template) ?
        new templates.ParentWrapper(attribute.template) :
      (attribute.template instanceof expressions.Expression) ?
        new templates.ParentWrapper(new saddle.DynamicText(attribute.template), attribute.template) :
      attribute.data;
  }
  return viewAttributes;
}

function dashToCamelCase(string) {
  return string.replace(/-./g, function(match) {
    return match.charAt(1).toUpperCase();
  });
}

function parseContentAttributes(content, view, viewAttributes) {
  var remaining = [];
  for (var i = 0, len = content.length; i < len; i++) {
    var item = content[i];
    var name = (item instanceof saddle.Element) && item.tag;

    if (name === 'attribute') {
      var name = parseNameAttribute(item);
      parseAttributeElement(item, name, viewAttributes);

    } else if (view.attributesMap && view.attributesMap[name]) {
      parseAttributeElement(item, name, viewAttributes);

    } else if (name === 'array') {
      var name = parseNameAttribute(item);
      parseArrayElement(item, name, viewAttributes);

    } else if (view.arraysMap && view.arraysMap[name]) {
      parseArrayElement(item, name, viewAttributes);

    } else {
      remaining.push(item);
    }
  }
  return remaining;
}

function parseNameAttribute(element) {
  var nameAttribute = element.attributes.name;
  var name = nameAttribute.data;
  if (!name) {
    throw new Error('The <' + element.tag + '> element requires a literal name attribute');
  }
  delete element.attributes.name;
  return name;
}

function parseAttributeElement(element, name, viewAttributes) {
  viewAttributes[name] = new templates.ParentWrapper(
    new saddle.Template(element.content)
  );
}

function parseArrayElement(element, name, viewAttributes) {
  var item = viewAttributesFromElement(element);
  if (!item.hasOwnProperty('content') && element.content.length) {
    item.content = new templates.ParentWrapper(
      new saddle.Template(element.content)
    );
  }
  var viewAttribute = viewAttributes[name] || (viewAttributes[name] = []);
  viewAttribute.push(item);
}

function parseViewExpression(expression) {
  // If there are multiple arguments separated by commas, they will get parsed
  // as a SequenceExpression
  var nameExpression, attributesExpression;
  if (expression instanceof expressions.SequenceExpression) {
    nameExpression = expression.args[0];
    attributesExpression = expression.args[1];
  } else {
    nameExpression = expression;
  }

  var viewAttributes = attributesFromExpression(attributesExpression);

  // A ViewPointer has a static name, and a DynamicViewPointer gets its name
  // at render time
  var viewPointer;
  if (nameExpression instanceof expressions.LiteralExpression) {
    var name = nameExpression.get();
    var view = findView(name);
    viewPointer = new templates.ViewPointer(name, viewAttributes, view);
  } else {
    viewPointer = new templates.DynamicViewPointer(nameExpression, viewAttributes);
  }
  parseNode.content.push(viewPointer);
}

function attributesFromExpression(expression) {
  if (!expression) return;

  var viewAttributes = new templates.ViewAttributes();

  // Turn a single object literal into a map with literal expressions as keys
  if (expression instanceof expressions.LiteralExpression) {
    var object = expression.value;
    if (typeof object !== 'object') unexpected();
    for (var key in object) {
      viewAttributes[key] = object[key];
    }
    return viewAttributes;

  // Get the expressions and keys from a OperatorExpression that would have been
  // created for an object literal with non-literal properties
  } else if (expression instanceof expressions.OperatorExpression && expression.name === '{}') {
    for (var i = 0, len = expression.args.length; i < len; i += 2) {
      var key = expression.args[i].value;
      var valueExpression = expression.args[i + 1];
      viewAttributes[key] = (valueExpression instanceof expressions.LiteralExpression) ?
        valueExpression.value :
        new templates.ParentWrapper(new saddle.DynamicText(valueExpression));
    }
    return viewAttributes;

  } else {
    unexpected();
  }
}

function parseValueExpression(expression) {
  var text = new saddle.DynamicText(expression);
  parseNode.content.push(text);
}

function ParseNode(view, parent) {
  this.view = view;
  this.parent = parent;
  this.content = [];
}
ParseNode.prototype.child = function() {
  return new ParseNode(this.view, this);
};
ParseNode.prototype.last = function() {
  return this.content[this.content.length - 1];
};

function parseText(data, onLiteral, onExpression) {
  var current = data;
  var last;
  while (current) {
    if (current === last) throw new Error('Error parsing template text: ' + data);
    last = current;

    var start = current.indexOf('{{');
    if (start === -1) {
      onLiteral(current);
      return;
    }

    var end = matchBraces(current, 2, start, '{', '}');
    if (end === -1) throw new Error('Mismatched braces in: ' + data);

    if (start > 0) {
      var before = current.slice(0, start);
      onLiteral(current.slice(0, start));
    }

    var inside = current.slice(start + 2, end - 2);
    if (inside) {
      var expression = createExpression(inside);
      onExpression(expression);
    }

    current = current.slice(end);
  }
}

function matchBraces(text, num, i, openChar, closeChar) {
  i += num;
  while (num) {
    var close = text.indexOf(closeChar, i);
    var open = text.indexOf(openChar, i);
    var hasClose = close !== -1;
    var hasOpen = open !== -1;
    if (hasClose && (!hasOpen || (close < open))) {
      i = close + 1;
      num--;
      continue;
    } else if (hasOpen) {
      i = open + 1;
      num++;
      continue;
    } else {
      return -1;
    }
  }
  return i;
}

var blockRegExp = /^(if|unless|else if|each|with)\s+([\s\S]+?)(?:\s+as\s+(\S+))?$/;
var valueRegExp = /^(?:(view|unbound|bound|unescaped)\s+)?([\s\S]*)/;

function createExpression(source) {
  source = source.trim();
  var meta = new expressions.ExpressionMeta(source);

  // Parse block expression //

  // The block expressions `if`, `unless`, `else if`, `each`, and `with` must
  // have a single blockType keyword and a path. They may have an optional
  // alias assignment
  var match = blockRegExp.exec(source);
  var path;
  if (match) {
    meta.blockType = match[1];
    path = match[2];
    meta.as = match[3];

  // The blocks `else`, `unbound`, and `bound` may not have a path or alias
  } else if (source === 'else' || source === 'unbound' || source === 'bound') {
    meta.blockType = source;

  // Any source that starts with a `/` is treated as an end block. Either a
  // `{{/}}` with no following characters or a `{{/if}}` style ending is valid
  } else if (source.charAt(0) === '/') {
    meta.isEnd = true;
    meta.blockType = source.slice(1).trim() || 'end';


  // Parse value expression //

  // A value expression has zero or many keywords and an expression
  } else {
    path = source;
    do {
      match = valueRegExp.exec(path);
      var keyword = match[1];
      path = match[2];
      if (keyword === 'unescaped') {
        meta.unescaped = true;
      } else if (keyword === 'unbound' || keyword === 'bound') {
        meta.bindType = keyword;
      } else if (keyword) {
        meta.valueType = keyword;
      }
    } while (keyword);
  }

  // Wrap parsing in a try / catch to add context to message when throwing
  try {
    var expression = (path) ?
      derbyExpressions.createPathExpression(path) :
      new expressions.Expression();
  } catch (err) {
    var message = '\n\nWithin expression: ' + source;
    throw appendErrorMessage(err, message);
  }
  expression.meta = meta;
  return expression;
}

function unexpected(source) {
  throw new Error('Error parsing template: ' + source);
}

function appendErrorMessage(err, message) {
  if (err instanceof Error) {
    err.message += message;
    return err;
  }
  return new Error(err + message);
}