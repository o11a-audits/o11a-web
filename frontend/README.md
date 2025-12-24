# o11a-web
The web client for o11a collaborative auditing

# Source Text Rendering

The o11a web client receives formatted html source text from the backend, removing the need for any front end formatting. The html recieved can be assumed to be 40 characters wide, making front end layout decisions easy.

# Hydration

The server renders the source text as HTML and sends it to the client. The audit source text is constant, but the info comments on the source nodes are not constant, and they need to be dynamically added above each node in the source text. The strategy for keeping initial renders of the source text fast, but still allowing for updating info comments above nodes in the source text dynamically is as follows: The client requests HTML for any source text it needs, renders it to the page, and caches it for later retrieval. The client then connects to the server by a websocket connection to receive cache-invalidation messages for the pre-rendered source text. When a user posts an info note, the server saves it and sends a message to the client with the topic id that was updated. Then the client can look up the metadata for the topic id, which includes scope, and use it to find all parents of the topic id as well. The client can then invalidate the cached HTML for those topic ids and request new HTML for them -- this new HTML will now include the added info comment.

If the server sends an update for a topic or parent topic that is currently in-view, the client should also dynamically replace the content of the dom node with the updated message. To enable this requirement, the server should send the new info message itself along with the topic id.

If the client disconnects from the server websocket, the client should invalidate all cached HTML and request new HTML for all currently visible topics to they can be updated with the latest info messages.

# Navigation Breadcrumb

Given that keyboard navigation is important in this application and running through convergences requires a lot of code-jumping, a back and forward key will be very important to get back to what you were looking at before jumping. Furthermore, maybe a breadcrumb would be beneficial to see your path. Even more than a linear breadcrumb that gets overridden when you go back and then to a new spot, a tree-like breadcrumb that preserves each history branch as you go forward and backward may be very useful. As the breadcrumb grows and is presented with lots of branches, maybe there would be a way to trim all other branches but the current one to get back to a simple history.

# Pane Management

Pane management for the application will be critical for its success. Given that all source text is 40 chars, it will be easy to work with. A tiling-window (pane in this case) manager approach could work very well, where each time a new pane is opened, it is automatically fit to the screen in a grid. Instead of a mouse-based hover-centric approach to exploring the codebase, a keyboard-centric pane-split and jump approach could work very well if done right. All panes being equal, it would be interesting, so a pane that displayed the source text for a function and a pane that displayed a single expression and its discussion would be presented in the same way. For any given pane, it could be added to the pane list or the quick view modal. The list would be a more durable view of the source you are working with, laid out in a list or grid of panes for navigation between. The quick view modal would be a more ephemeral view where the pane is hovered in the center of the screen above the list view, for digging down into the source in a quick context. Good navigation between the quick view modal and list would have to be carefully considered, but I assume that as long as the quick view modal is presented, the grid would not be navigable. I think, though the list is presented differently, the quick view modal and the panes in the list will essentially behave the same because they should both implement the same branching history. The quick view modal is mainly a focused, easy-to-dismiss view of a pane.
