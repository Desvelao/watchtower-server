export const isRequired = label => value =>
  value ? true : `${label} is required.`;
export const isDefined = label => value =>
  typeof value !== 'undefined' ? true : `${label} should be defined.`;
export const stringHasMaxChars = (length, label) => value =>
  value.length <= length
    ? true
    : `${label} must be less than ${length} characters.`;
export const stringMatchRegex = (regex, message) => value =>
  regex.test(value) || message;
export const isOneOf = array => value =>
  array.includes(value) || `Allowed values: ${array.join(', ')}`;
export const isURL = stringMatchRegex(/^https?:\/\//, 'URL not valid.');
