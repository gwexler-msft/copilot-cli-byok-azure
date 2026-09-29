import querystring from 'querystring';

const headerNames = ['authorization', 'api-key', 'x-api-key', 'ocp-apim-subscription-key'];
const queryNames = headerNames.concat(['subscription-key', 'access_token']);

function validValue(value) {
  return typeof value === 'string' && /^[\x21-\x7e]+$/.test(value) && !/[,|]/.test(value);
}

function credential(request) {
  try {
    const headers = request.rawHeadersIn.filter(header => headerNames.includes(header[0].toLowerCase()));
    const query = querystring.parse(request.variables.args || '', '&', '=', { maxKeys: 0 });
    const names = Object.keys(query).filter(name => queryNames.includes(name.toLowerCase()));
    if (headers.length + names.length !== 1) return 'invalid';
    if (names.length === 1) {
      return names[0].toLowerCase() === 'api-key' && validValue(query[names[0]]) ? 'query' : 'invalid';
    }
    const name = headers[0][0].toLowerCase();
    const value = headers[0][1];
    if (name === 'api-key' && validValue(value)) return 'header:' + value;
    if (name !== 'authorization') return 'invalid';
    const bearer = /^Bearer ([A-Za-z0-9._~+\/=-]+)$/i.exec(value);
    return bearer ? 'header:' + bearer[1] : 'invalid';
  } catch (error) {
    return 'invalid';
  }
}

export default { credential };