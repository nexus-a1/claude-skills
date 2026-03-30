# Brainstorm Skill - Example Output

This example shows what to expect when using `/brainstorm` for a typical feature request.

## Scenario

**Business Request:**
> "We need to let users export their order history to Excel. Customers are asking for this feature to do their own analysis."

**Running:**
```bash
/brainstorm "Add Excel export for order history"
```

---

## Phase 1: Requirements Gathering

**Feature:** Add Excel export for order history

**Business Context Captured:**
- Driver: Customer requirement
- Urgency: Medium (on roadmap)
- Constraints: Must work with existing order query system

---

## Phase 2: Exploration Results

### Codebase Exploration
```
Found similar implementations:
1. src/Service/Report/PdfExportService.php
   - Pattern for generating reports from orders
   - Uses Symfony service layer

2. src/Controller/Api/Orders/ExportController.php
   - Existing CSV export endpoint
   - Good reference for filters and pagination

3. src/Entity/Order.php
   - Entity structure we're exporting
   - Related: OrderItem, Customer, Payment

Key patterns identified:
- Service layer for business logic
- Invokable controllers (one per HTTP method)
- Request/Response models for validation
```

### Business Analysis
```
Core Problem: Users can't analyze their order data outside the platform
User Personas: Business customers doing accounting, bulk buyers
Success Metrics: Download completion rate, file usability
Edge Cases:
  - Very large order histories (10k+ orders)
  - Orders with special characters in items
  - Date range filtering
  - Different locales/currencies
```

---

## Phase 3: Implementation Approaches

### Approach 1: PhpSpreadsheet (Full-Featured)

**Complexity:** Moderate | **Timeline:** 3-5 days

**Architecture:**
- Backend service using PhpSpreadsheet library
- Generate .xlsx files with formatting, headers, formulas
- Stream response for memory efficiency

**Pros:**
✓ Rich formatting (colors, formulas, multiple sheets)
✓ Professional-looking output
✓ Can include charts and summaries
✓ Single library, well-maintained

**Cons:**
✗ Memory intensive for large datasets
✗ Slower generation than CSV
✗ Additional dependency

**Best for:** Users who need professional Excel files with formatting

---

### Approach 2: CSV Export + Client-Side Conversion

**Complexity:** Simple | **Timeline:** 1-2 days

**Architecture:**
- Backend generates CSV
- Frontend converts to Excel using SheetJS
- All processing client-side

**Pros:**
✓ Simple backend implementation
✓ Lightweight, fast
✓ Can reuse existing CSV logic
✓ No server memory concerns

**Cons:**
✗ Limited to basic formatting
✗ Client-side processing (slower for large files)
✗ Requires JavaScript enabled
✗ Less control over output format

**Best for:** Quick implementation, basic export needs

---

### Approach 3: Async Job with AWS Lambda

**Complexity:** Complex | **Timeline:** 1-2 weeks

**Architecture:**
- Trigger background job when user requests export
- AWS Lambda generates file, stores in S3
- Email user when ready / polling for status

**Pros:**
✓ Handles arbitrarily large datasets
✓ No impact on web server performance
✓ Scalable to many concurrent requests
✓ Can do complex processing

**Cons:**
✗ Much more complex infrastructure
✗ Additional AWS costs
✗ Delayed delivery (not instant download)
✗ Requires queue system (SQS)

**Best for:** Enterprise scale, massive datasets

---

## User Selection

**User chose:** Approach 2 (CSV + Client-Side)

**Reasoning:**
- Quick to implement
- Meets current needs (most users have < 1000 orders)
- Can upgrade later if needed

---

## Phase 4: Implementation Picture (Refined)

### Components

**Backend:**
```
Service/Order/ExportOrderHistoryService.php
├─ Purpose: Generate CSV from order query results
├─ Methods:
│  └─ export(OrderQueryInterface $query): string
├─ Dependencies: OrderRepository, TransformerService
└─ Responsibility: Transform Order entities to CSV rows

Controller/Api/Orders/Export/GetController.php
├─ Purpose: Handle GET /api/orders/export
├─ Validates: Date ranges, filters
└─ Returns: CSV file with proper headers

Model/Orders/Export/GetRequest.php
├─ Purpose: Validate export request parameters
└─ Fields: startDate, endDate, status, customerId
```

**Frontend:**
```
components/OrderHistory/ExportButton.tsx
├─ Purpose: Trigger export and convert to Excel
├─ Uses: SheetJS (xlsx library)
└─ Flow: API call → CSV → Convert → Download
```

### Data Flow

1. User clicks "Export to Excel" button
2. Frontend calls GET /api/orders/export?startDate=X&endDate=Y
3. Controller validates request (GetRequest model)
4. Service queries OrderRepository with filters
5. Service transforms Order entities → CSV rows
6. Backend returns CSV with Content-Type: text/csv
7. Frontend receives CSV response
8. SheetJS converts CSV → .xlsx in browser
9. Browser triggers download of Excel file

### Database Changes

**None required** - Uses existing Order schema

### API Design

#### GET /api/orders/export

**Request Parameters:**
```
startDate: string (YYYY-MM-DD, optional)
endDate: string (YYYY-MM-DD, optional)
status: string[] (optional, e.g., ["completed", "shipped"])
customerId: int (optional, for admin use)
```

**Response:**
```
Content-Type: text/csv
Content-Disposition: attachment; filename="orders-export.csv"

OrderID,Date,Customer,Total,Status,Items
12345,2025-01-15,John Doe,99.99,completed,"Item A, Item B"
12346,2025-01-16,Jane Smith,149.99,shipped,"Item C"
```

**Error Cases:**
- 400: Invalid date format
- 403: Unauthorized (not customer's orders)
- 413: Too many orders (> 10,000 limit)

### Security

- **Authentication:** Required (JWT token)
- **Authorization:** Users can only export their own orders (admins can export any)
- **Rate Limiting:** Max 5 exports per minute per user
- **Data Validation:** Sanitize all parameters to prevent injection
- **Data Filtering:** Never expose sensitive payment details

### Testing

**Unit Tests:**
- ExportOrderHistoryService: transforms entities correctly
- GetController: validates parameters
- GetRequest: validation rules work

**Integration Tests:**
- Full export flow with real database
- Large dataset handling (1000+ orders)
- Filter combinations work correctly

**Manual Testing:**
- Download Excel file and open in Microsoft Excel
- Verify all columns present and formatted correctly
- Test with special characters (€, £, ñ)
- Test date range filtering

---

## Phase 5: Work Breakdown

### 1. Backend CSV Service
**Type:** Backend
**Estimate:** Small (< 1 day)

**Description:** Create service to transform Order entities to CSV format

**Files:**
- `src/Service/Order/ExportOrderHistoryService.php` (new)
- `tests/Service/Order/ExportOrderHistoryServiceTest.php` (new)

**Dependencies:** None
**Acceptance Criteria:**
- [ ] Service converts Order to CSV row
- [ ] Handles null values gracefully
- [ ] Escapes special characters
- [ ] Unit tests pass

---

### 2. API Endpoint
**Type:** Backend
**Estimate:** Small (< 1 day)

**Description:** Create GET endpoint for export

**Files:**
- `src/Controller/Api/Orders/Export/GetController.php` (new)
- `src/Model/Orders/Export/GetRequest.php` (new)
- `src/Model/Orders/Export/GetResponse.php` (new)
- `config/routes/orders.yaml` (modify)

**Dependencies:** #1 (CSV Service)
**Acceptance Criteria:**
- [ ] Endpoint returns CSV with proper headers
- [ ] Request validation works
- [ ] Authorization checks pass
- [ ] Rate limiting applied

---

### 3. Frontend Export Button
**Type:** Frontend
**Estimate:** Medium (1 day)

**Description:** Add export button and Excel conversion

**Files:**
- `frontend/src/components/OrderHistory/ExportButton.tsx` (new)
- `frontend/src/components/OrderHistory/OrderHistoryPage.tsx` (modify)
- `package.json` (add xlsx dependency)

**Dependencies:** #2 (API Endpoint)
**Acceptance Criteria:**
- [ ] Button appears on order history page
- [ ] Clicking button downloads Excel file
- [ ] Loading state during export
- [ ] Error handling with user-friendly messages

---

### 4. Integration Tests
**Type:** Testing
**Estimate:** Small (0.5 day)

**Description:** End-to-end test of export flow

**Files:**
- `tests/Integration/Api/Orders/ExportTest.php` (new)

**Dependencies:** #1, #2, #3
**Acceptance Criteria:**
- [ ] Test full export with 100+ orders
- [ ] Test date filtering
- [ ] Test authorization (can't export other user's orders)
- [ ] Test rate limiting

---

### 5. Documentation
**Type:** Documentation
**Estimate:** Small (0.5 day)

**Description:** Document new feature

**Files:**
- `docs/api/orders.md` (modify)
- `CHANGELOG.md` (modify)

**Dependencies:** Can start anytime
**Acceptance Criteria:**
- [ ] API endpoint documented
- [ ] User guide updated with export instructions
- [ ] Changelog entry added

---

## Work Item Flow

```
[1] CSV Service
     ↓
[2] API Endpoint
     ↓
[3] Frontend Button
     ↓
[4] Integration Tests

[5] Documentation (parallel - can start anytime)
```

**Total Estimated Effort:** 3-4 days

---

## Phase 6: Summary

### Files Created

```
.claude/brainstorm/excel-export-orders/
├── exploration.md              # Codebase patterns found
├── business-context.md         # Requirements analysis
├── approaches.md               # 3 options evaluated
├── implementation-picture.md   # Detailed design
├── work-breakdown.md           # 5 work items
└── brainstorm-summary.md       # Complete summary
```

### Key Decisions

**Decision:** Use CSV + Client-Side conversion (Approach 2)
**Why:** Balances simplicity, speed, and meets current needs. Can upgrade to PhpSpreadsheet later if rich formatting becomes important.

**Decision:** Rate limit to 5 exports/minute
**Why:** Prevent abuse while allowing legitimate use cases.

**Decision:** 10,000 order limit per export
**Why:** Prevents server overload and excessive memory use.

### Risks & Mitigations

**Risk:** Large datasets crash browser during conversion
**Mitigation:** Display warning for exports > 5000 orders. Implement pagination if needed.

**Risk:** Users expect advanced Excel features (formulas, charts)
**Mitigation:** Document limitations. Plan upgrade to PhpSpreadsheet if users request.

---

## Next Steps

You can now:

1. **Create detailed requirements:**
   ```bash
   /create-requirements
   ```
   Use this brainstorm as basis for comprehensive specs.

2. **Start implementing:**
   - Work items are small enough to implement directly
   - Start with #1 (CSV Service)

3. **Create epic (if part of larger effort):**
   ```bash
   /epic "Order export and reporting features"
   ```

4. **Review with stakeholders:**
   - Share `brainstorm-summary.md` for alignment
   - Get approval on approach before coding

---

## Summary

**What we learned:**
- Multiple viable approaches exist
- CSV + client-side is simplest and fastest
- 3-4 days of effort, 5 work items
- No database changes needed
- Clear path to implementation

**Confidence level:** High
**Ready to implement:** Yes
