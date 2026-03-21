// Custom error class to attach the enhanced response object
export class HTTPError extends Error {
  constructor(message, response) {
    super(message);
    this.name = "HTTPError";
    this.response = response;
  }
}

export async function http(url, options) {
  // Destructure options to separate body and headers from others.
  const { body, headers = {}, ...restOptions } = options;

  // Normalize headers into a Headers instance.
  let finalHeaders =
    headers instanceof Headers ? headers : new Headers(headers);

  // If there is a body and the Content-Type header indicates JSON,
  // automatically stringify the body if it's not already a string.
  const reqContentType = finalHeaders.get("Content-Type");
  let finalBody = body;
  if (body && reqContentType && reqContentType.includes("application/json")) {
    if (typeof body !== "string") {
      finalBody = JSON.stringify(body);
    }
  }

  const rawResponse = await fetch(url, {
    ...restOptions,
    body: finalBody,
    headers: finalHeaders,
  });

  // Read and parse the response based on its Content-Type.
  const respContentType = rawResponse.headers.get("Content-Type") || "";
  let parsedBody;

  if (respContentType.includes("application/json")) {
    // Use clone() because reading the body consumes the stream.
    parsedBody = await rawResponse.clone().json();
  } else if (respContentType.includes("text/")) {
    parsedBody = await rawResponse.clone().text();
  } else {
    // For other content types, use blob() as a default.
    parsedBody = await rawResponse.clone().blob();
  }

  const enhancedResponse = {
    ok: rawResponse.ok,
    status: rawResponse.status,
    statusText: rawResponse.statusText,
    headers: rawResponse.headers,
    url: rawResponse.url,
    redirected: rawResponse.redirected,
    type: rawResponse.type,
    body: parsedBody, // <-- now holds the parsed data
  };

  // If the HTTP status indicates a failure, throw an error that includes the enhanced response
  if (!enhancedResponse.ok) {
    throw new HTTPError(
      `HTTP error! status: ${rawResponse.status}`,
      enhancedResponse,
    );
  }

  // Construct and return a new object that carries over key properties from the original response,
  // but with the body replaced by the parsed content.
  return enhancedResponse;
}
